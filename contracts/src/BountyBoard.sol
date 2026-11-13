// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPayoutModule} from "./interfaces/IPayoutModule.sol";

/// @title BountyBoard
/// @notice Post / enter / submit / finalize / settle with escrow, burn-to-post and a
///         GMV rake routed to the Treasury. Two verification lanes:
///
///         LANE A — AutoGrade: a trusted grader signs an EIP-712 attestation naming the
///         ranked winners; finalize opens a public-rerun CHALLENGE window; settle pays.
///         Grader signer is rotatable + pausable; the arbiter can void a bad attestation.
///
///         LANE B — PosterJudge (subjective bounties): poster posts a BOND at creation,
///         calls selectWinner, which opens a DISPUTE window; an entrant can dispute; the
///         platform arbiter resolves and may SLASH the poster bond (rug-judge / ghost).
///
///         Anti-rug (both lanes): once any entry exists the poster can never withdraw
///         the reward; escrow only leaves on a valid attestation, a clean poster
///         selection, or an arbiter decision.
///
/// @dev Escrow is held in this contract. `escrowed[token]` ghost-tracks the exact
///      outstanding obligation per token; `balanceOf(this) == escrowed[token]` is the
///      board-side half of the system solvency invariant. CEI + nonReentrant on every
///      value-moving function.
contract BountyBoard is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    enum Mode {
        AutoGrade,
        PosterJudge
    }

    enum State {
        None,
        Open,
        Finalized, // AutoGrade: attested, in challenge window
        Selected, // PosterJudge: poster/arbiter picked, in dispute window (or ready)
        Disputed, // PosterJudge: entrant disputed, awaiting arbiter
        Settled,
        Cancelled
    }

    struct Bounty {
        address poster;
        Mode mode;
        State state;
        address rewardToken;
        uint256 rewardAmount;
        uint256 bondAmount; // TICKET bond (PosterJudge only)
        uint64 deadline;
        uint64 settleAfter; // challenge/dispute window end
        uint32 gmvRakeBps; // snapshot at post
        uint64 attestNonce; // bumped by arbiter to void an attestation
        bytes32 metricHash;
        bytes32 category;
        uint64 entryCount;
        address selectedWinner; // PosterJudge
        bool bondSlashed; // PosterJudge resolution flag
    }

    /// @notice EIP-712 attestation signed by the grader for AutoGrade bounties.
    struct Attestation {
        uint256 bountyId;
        bytes32 metricHash;
        address[] winners;
        uint256[] weightsBps; // must sum to 10_000
        uint256 nonce; // must equal bounty.attestNonce
        uint256 expiry; // signature expiry (unix)
    }

    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(uint256 bountyId,bytes32 metricHash,address[] winners,uint256[] weightsBps,uint256 nonce,uint256 expiry)"
    );

    uint256 internal constant BPS = 10_000;

    // immutable wiring
    ERC20Burnable public immutable ticket;
    IPayoutModule public immutable payoutModule;
    address public treasury; // StockVault — receives rake + slashed bonds

    // roles / params
    address public graderSigner;
    bool public graderPaused;
    address public arbiter;

    uint32 public burnBps = 400; // 4% of reward value, burned in TICKET
    uint256 public minBurnFloor = 1e18; // min TICKET burned per post
    uint32 public bondBps = 1000; // 10% of reward value, TICKET bond (PosterJudge)
    uint256 public minBondFloor = 1e18;
    uint32 public gmvRakeBps = 400; // 4% of reward → treasury at settle
    uint64 public challengeWindow = 2 days; // AutoGrade public-rerun window
    uint64 public disputeWindow = 2 days; // PosterJudge dispute window
    uint64 public expiryGrace = 7 days; // grader-timeout refund grace (AutoGrade)

    uint256 public bountyCount;
    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => mapping(address => bool)) public hasEntered;
    // AutoGrade winner set (stored on finalize)
    mapping(uint256 => address[]) private _winners;
    mapping(uint256 => uint256[]) private _weights;

    /// @notice Outstanding escrow obligation per token (reward + bond). Board-side
    ///         solvency ghost: invariant is balanceOf(this) == escrowed[token].
    mapping(address => uint256) public escrowed;

    // ------------------------------------------------------------------ events
    event BountyPosted(
        uint256 indexed id,
        address indexed poster,
        Mode mode,
        bytes32 indexed category,
        address rewardToken,
        uint256 rewardAmount,
        uint256 burned,
        uint256 bond,
        uint64 deadline
    );
    event Entered(uint256 indexed id, address indexed agent);
    event Submitted(uint256 indexed id, address indexed agent, bytes32 repoCommitHash, bytes32 transcriptHash);
    event Finalized(uint256 indexed id, bytes32 attestationHash, uint64 settleAfter);
    event WinnerSelected(uint256 indexed id, address indexed winner, uint64 settleAfter);
    event Disputed(uint256 indexed id, address indexed disputer);
    event ArbiterResolved(uint256 indexed id, address indexed winner, bool bondSlashed);
    event AttestationVoided(uint256 indexed id, uint64 newNonce);
    event Settled(uint256 indexed id, uint256 rake, uint256 paid);
    event Cancelled(uint256 indexed id, uint256 refunded, uint256 bondReturned);
    event Refunded(uint256 indexed id, uint256 refunded, uint256 bondReturned);

    event GraderSignerSet(address signer);
    event GraderPaused(bool paused);
    event ArbiterSet(address arbiter);
    event TreasurySet(address treasury);
    event ParamsSet(uint32 burnBps, uint256 minBurnFloor, uint32 bondBps, uint256 minBondFloor, uint32 gmvRakeBps);
    event WindowsSet(uint64 challengeWindow, uint64 disputeWindow, uint64 expiryGrace);

    // ------------------------------------------------------------------ errors
    error BadParam();
    error NotPoster();
    error NotArbiter();
    error WrongMode();
    error WrongState();
    error NotEntrant();
    error AlreadyEntered();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error EntriesExist();
    error WindowOpen();
    error WindowClosed();
    error GraderPausedErr();
    error BadAttestation();
    error BadSignature();

    constructor(
        address owner_,
        ERC20Burnable ticket_,
        IPayoutModule payoutModule_,
        address treasury_,
        address graderSigner_,
        address arbiter_
    ) Ownable(owner_) EIP712("AgentBountyBoard", "1") {
        if (
            address(ticket_) == address(0) || address(payoutModule_) == address(0) || treasury_ == address(0)
                || graderSigner_ == address(0) || arbiter_ == address(0)
        ) revert BadParam();
        ticket = ticket_;
        payoutModule = payoutModule_;
        treasury = treasury_;
        graderSigner = graderSigner_;
        arbiter = arbiter_;
    }

    // --------------------------------------------------------------- modifiers
    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    // ----------------------------------------------------------------- admin
    function setGraderSigner(address s) external onlyOwner {
        if (s == address(0)) revert BadParam();
        graderSigner = s;
        emit GraderSignerSet(s);
    }

    function setGraderPaused(bool p) external onlyOwner {
        graderPaused = p;
        emit GraderPaused(p);
    }

    function setArbiter(address a) external onlyOwner {
        if (a == address(0)) revert BadParam();
        arbiter = a;
        emit ArbiterSet(a);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert BadParam();
        treasury = t;
        emit TreasurySet(t);
    }

    function setParams(
        uint32 burnBps_,
        uint256 minBurnFloor_,
        uint32 bondBps_,
        uint256 minBondFloor_,
        uint32 gmvRakeBps_
    ) external onlyOwner {
        if (burnBps_ > BPS || bondBps_ > BPS || gmvRakeBps_ > BPS) revert BadParam();
        burnBps = burnBps_;
        minBurnFloor = minBurnFloor_;
        bondBps = bondBps_;
        minBondFloor = minBondFloor_;
        gmvRakeBps = gmvRakeBps_;
        emit ParamsSet(burnBps_, minBurnFloor_, bondBps_, minBondFloor_, gmvRakeBps_);
    }

    function setWindows(uint64 challengeWindow_, uint64 disputeWindow_, uint64 expiryGrace_) external onlyOwner {
        challengeWindow = challengeWindow_;
        disputeWindow = disputeWindow_;
        expiryGrace = expiryGrace_;
        emit WindowsSet(challengeWindow_, disputeWindow_, expiryGrace_);
    }

    // ------------------------------------------------------------------- views
    function getBounty(uint256 id) external view returns (Bounty memory) {
        return _bounties[id];
    }

    function getWinners(uint256 id) external view returns (address[] memory, uint256[] memory) {
        return (_winners[id], _weights[id]);
    }

    /// @notice Preview the TICKET-denominated value of a reward (TICKET or allowlisted stock).
    function rewardValueInTicket(address rewardToken, uint256 rewardAmount) public view returns (uint256) {
        if (rewardToken == address(ticket)) return rewardAmount;
        return payoutModule.quoteStockToTicket(rewardToken, rewardAmount);
    }

    // ------------------------------------------------------------------- post
    /// @notice Post a bounty. Poster BURNS $TICKET (burn-to-post) and deposits the reward
    ///         into escrow. PosterJudge bounties also post a TICKET bond.
    function postBounty(
        Mode mode,
        bytes32 category,
        bytes32 metricHash,
        address rewardToken,
        uint256 rewardAmount,
        uint64 deadline
    ) external nonReentrant returns (uint256 id) {
        if (rewardAmount == 0 || deadline <= block.timestamp) revert BadParam();
        if (rewardToken != address(ticket) && !payoutModule.isAllowed(rewardToken)) revert BadParam();

        uint256 valueInTicket = rewardValueInTicket(rewardToken, rewardAmount);

        // burn-to-post (permanent sink) — pulled & burned straight from poster
        uint256 burnAmt = _max(valueInTicket * burnBps / BPS, minBurnFloor);
        ticket.burnFrom(msg.sender, burnAmt);

        // reward into escrow
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rewardAmount);
        escrowed[rewardToken] += rewardAmount;

        uint256 bond;
        if (mode == Mode.PosterJudge) {
            bond = _max(valueInTicket * bondBps / BPS, minBondFloor);
            IERC20(address(ticket)).safeTransferFrom(msg.sender, address(this), bond);
            escrowed[address(ticket)] += bond;
        }

        id = ++bountyCount;
        _bounties[id] = Bounty({
            poster: msg.sender,
            mode: mode,
            state: State.Open,
            rewardToken: rewardToken,
            rewardAmount: rewardAmount,
            bondAmount: bond,
            deadline: deadline,
            settleAfter: 0,
            gmvRakeBps: gmvRakeBps,
            attestNonce: 0,
            metricHash: metricHash,
            category: category,
            entryCount: 0,
            selectedWinner: address(0),
            bondSlashed: false
        });

        emit BountyPosted(id, msg.sender, mode, category, rewardToken, rewardAmount, burnAmt, bond, deadline);
    }

    // ------------------------------------------------------------------ enter
    /// @notice FREE entry — no stake, no fee.
    function enter(uint256 id) external {
        Bounty storage b = _bounties[id];
        if (b.state != State.Open) revert WrongState();
        if (block.timestamp > b.deadline) revert DeadlinePassed();
        if (hasEntered[id][msg.sender]) revert AlreadyEntered();
        hasEntered[id][msg.sender] = true;
        unchecked {
            b.entryCount += 1;
        }
        emit Entered(id, msg.sender);
    }

    /// @notice Record a submission (provenance hashes; off-chain grader reads them).
    function submit(uint256 id, bytes32 repoCommitHash, bytes32 transcriptHash) external {
        Bounty storage b = _bounties[id];
        if (b.state != State.Open) revert WrongState();
        if (block.timestamp > b.deadline) revert DeadlinePassed();
        if (!hasEntered[id][msg.sender]) revert NotEntrant();
        emit Submitted(id, msg.sender, repoCommitHash, transcriptHash);
    }

    // -------------------------------------------------- LANE A: AutoGrade
    /// @notice Finalize an AutoGrade bounty with the grader's signed attestation.
    ///         Opens the public-rerun challenge window; does not move funds yet.
    function finalize(uint256 id, Attestation calldata att, bytes calldata sig) external nonReentrant {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.AutoGrade) revert WrongMode();
        if (b.state != State.Open) revert WrongState();
        if (graderPaused) revert GraderPausedErr();
        if (block.timestamp < b.deadline) revert DeadlineNotPassed();

        if (
            att.bountyId != id || att.metricHash != b.metricHash || att.nonce != b.attestNonce
                || att.expiry < block.timestamp || att.winners.length == 0
                || att.winners.length != att.weightsBps.length
        ) revert BadAttestation();

        uint256 sum;
        for (uint256 i; i < att.winners.length; ++i) {
            if (!hasEntered[id][att.winners[i]]) revert BadAttestation();
            sum += att.weightsBps[i];
        }
        if (sum != BPS) revert BadAttestation();

        bytes32 digest = _hashAttestation(att);
        address rec = ECDSA.recover(digest, sig);
        if (rec != graderSigner) revert BadSignature();

        _winners[id] = att.winners;
        _weights[id] = att.weightsBps;
        b.state = State.Finalized;
        b.settleAfter = uint64(block.timestamp) + challengeWindow;

        emit Finalized(id, digest, b.settleAfter);
    }

    /// @notice Arbiter voids a finalized attestation during the challenge window
    ///         (public-rerun dispute upheld). Bumps the nonce so the old sig is dead
    ///         and reopens the bounty for a corrected attestation.
    function voidAttestation(uint256 id) external onlyArbiter {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.AutoGrade) revert WrongMode();
        if (b.state != State.Finalized) revert WrongState();
        if (block.timestamp >= b.settleAfter) revert WindowClosed();
        delete _winners[id];
        delete _weights[id];
        b.state = State.Open;
        b.settleAfter = 0;
        unchecked {
            b.attestNonce += 1;
        }
        emit AttestationVoided(id, b.attestNonce);
    }

    // -------------------------------------------------- LANE B: PosterJudge
    /// @notice Poster picks a winner for a subjective bounty. Opens the dispute window.
    function selectWinner(uint256 id, address winner) external {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.PosterJudge) revert WrongMode();
        if (msg.sender != b.poster) revert NotPoster();
        if (b.state != State.Open) revert WrongState();
        if (b.entryCount == 0) revert NotEntrant();
        if (!hasEntered[id][winner]) revert NotEntrant();

        b.selectedWinner = winner;
        b.state = State.Selected;
        b.settleAfter = uint64(block.timestamp) + disputeWindow;
        emit WinnerSelected(id, winner, b.settleAfter);
    }

    /// @notice An entrant disputes the poster's pick during the dispute window.
    function dispute(uint256 id) external {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.PosterJudge) revert WrongMode();
        if (b.state != State.Selected) revert WrongState();
        if (block.timestamp >= b.settleAfter) revert WindowClosed();
        if (!hasEntered[id][msg.sender] || msg.sender == b.poster) revert NotEntrant();
        b.state = State.Disputed;
        emit Disputed(id, msg.sender);
    }

    /// @notice Arbiter resolves. Handles (a) a disputed pick and (b) a ghosting poster
    ///         who never selected before deadline+grace. May SLASH the bond (→ treasury)
    ///         if the poster rejected a clearly-valid entry or ghosted.
    function arbiterResolve(uint256 id, address winner, bool slashBond) external onlyArbiter {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.PosterJudge) revert WrongMode();
        bool disputed = b.state == State.Disputed;
        bool ghosted = b.state == State.Open && block.timestamp > b.deadline + expiryGrace && b.entryCount > 0;
        if (!disputed && !ghosted) revert WrongState();
        if (!hasEntered[id][winner]) revert NotEntrant();

        b.selectedWinner = winner;
        b.bondSlashed = slashBond;
        b.state = State.Selected;
        b.settleAfter = uint64(block.timestamp); // immediately settleable
        emit ArbiterResolved(id, winner, slashBond);
    }

    // ------------------------------------------------------------------ settle
    /// @notice Release escrow after the window closes. Pays winner(s) minus the GMV
    ///         rake (→ treasury). PosterJudge returns the bond to the poster, or sends
    ///         it to the treasury if the arbiter slashed it.
    function settle(uint256 id) external nonReentrant {
        Bounty storage b = _bounties[id];
        if (b.state != State.Finalized && b.state != State.Selected) revert WrongState();
        if (block.timestamp < b.settleAfter) revert WindowOpen();

        address token = b.rewardToken;
        uint256 reward = b.rewardAmount;
        uint256 rake = reward * b.gmvRakeBps / BPS;
        uint256 payout = reward - rake;

        // effects: clear escrow obligations before any transfer (CEI)
        escrowed[token] -= reward;
        uint256 bond = b.bondAmount;
        if (bond != 0) {
            escrowed[address(ticket)] -= bond;
        }
        b.state = State.Settled;

        // interactions
        if (rake != 0) {
            IERC20(token).safeTransfer(treasury, rake);
        }

        if (b.mode == Mode.AutoGrade) {
            address[] memory ws = _winners[id];
            uint256[] memory wts = _weights[id];
            uint256 distributed;
            for (uint256 i; i < ws.length; ++i) {
                uint256 amt = (i == ws.length - 1) ? (payout - distributed) : (payout * wts[i] / BPS);
                distributed += amt;
                if (amt != 0) IERC20(token).safeTransfer(ws[i], amt);
            }
        } else {
            if (payout != 0) IERC20(token).safeTransfer(b.selectedWinner, payout);
            if (bond != 0) {
                if (b.bondSlashed) {
                    IERC20(address(ticket)).safeTransfer(treasury, bond);
                } else {
                    IERC20(address(ticket)).safeTransfer(b.poster, bond);
                }
            }
        }

        emit Settled(id, rake, payout);
    }

    // ---------------------------------------------------------- cancel / refund
    /// @notice Poster cancels ONLY while no entries exist (anti-rug). Reward + bond
    ///         return to the poster; the burn is permanent and not refunded.
    function cancelBounty(uint256 id) external nonReentrant {
        Bounty storage b = _bounties[id];
        if (msg.sender != b.poster) revert NotPoster();
        if (b.state != State.Open) revert WrongState();
        if (b.entryCount != 0) revert EntriesExist();

        uint256 reward = b.rewardAmount;
        uint256 bond = b.bondAmount;
        escrowed[b.rewardToken] -= reward;
        if (bond != 0) escrowed[address(ticket)] -= bond;
        b.state = State.Cancelled;

        IERC20(b.rewardToken).safeTransfer(b.poster, reward);
        if (bond != 0) IERC20(address(ticket)).safeTransfer(b.poster, bond);
        emit Cancelled(id, reward, bond);
    }

    /// @notice Safety valve for AutoGrade only: if the grader never attests within
    ///         deadline + grace, the reward (and there is no bond) returns to the poster
    ///         so funds are never permanently locked by a grader outage. PosterJudge
    ///         ghosting is handled by the arbiter instead (so the bond stays slashable).
    function refundExpired(uint256 id) external nonReentrant {
        Bounty storage b = _bounties[id];
        if (b.mode != Mode.AutoGrade) revert WrongMode();
        if (b.state != State.Open) revert WrongState();
        if (block.timestamp <= uint256(b.deadline) + expiryGrace) revert WindowOpen();

        uint256 reward = b.rewardAmount;
        escrowed[b.rewardToken] -= reward;
        b.state = State.Cancelled;
        IERC20(b.rewardToken).safeTransfer(b.poster, reward);
        emit Refunded(id, reward, 0);
    }

    // --------------------------------------------------------------- internals
    function _hashAttestation(Attestation calldata att) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                att.bountyId,
                att.metricHash,
                keccak256(abi.encodePacked(att.winners)),
                keccak256(abi.encodePacked(att.weightsBps)),
                att.nonce,
                att.expiry
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _max(uint256 a, uint256 c) internal pure returns (uint256) {
        return a >= c ? a : c;
    }
}
