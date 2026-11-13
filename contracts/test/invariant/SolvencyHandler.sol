// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {BountyBoard} from "../../src/BountyBoard.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {Staking} from "../../src/Staking.sol";
import {StockVault} from "../../src/StockVault.sol";
import {TICKET} from "../../src/TICKET.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives random sequences of posts / entries / finalizes / settles / revenue
///         distribution / staking / claims across BOTH lanes, so the invariant suite can
///         assert solvency holds no matter the ordering.
contract SolvencyHandler is CommonBase, StdUtils, StdCheats {
    BountyBoard public board;
    FeeRouter public router;
    Staking public staking;
    StockVault public vault;
    TICKET public ticket;
    MockERC20 public stock;
    uint256 graderPk;
    address graderSigner;
    address arbiter;

    address[] public actors;
    uint256[] public bountyIds;
    mapping(uint256 => address[]) public entrants;
    mapping(uint256 => mapping(address => bool)) entered;

    bytes32 constant METRIC = keccak256("metric");
    bytes32 constant ATTEST_TYPEHASH = keccak256(
        "Attestation(uint256 bountyId,bytes32 metricHash,address[] winners,uint256[] weightsBps,uint256 nonce,uint256 expiry)"
    );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // ghost totals for the "no money printing" check
    uint256 public ghostStockIntoSystem; // stock minted into board escrow + router revenue
    uint256 public ghostStockOut; // stock paid to winners + stakers (leaves the system)

    constructor(
        BountyBoard _board,
        FeeRouter _router,
        Staking _staking,
        StockVault _vault,
        TICKET _ticket,
        MockERC20 _stock,
        uint256 _graderPk,
        address _arbiter,
        address[] memory _actors
    ) {
        board = _board;
        router = _router;
        staking = _staking;
        vault = _vault;
        ticket = _ticket;
        stock = _stock;
        graderPk = _graderPk;
        graderSigner = vm.addr(_graderPk);
        arbiter = _arbiter;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ------------------------------------------------------------- post
    function postAuto(uint256 actorSeed, uint256 rewardSeed) public {
        address a = _actor(actorSeed);
        uint256 reward = bound(rewardSeed, 1e18, 50e18);
        stock.mint(a, reward);
        ghostStockIntoSystem += reward;
        vm.prank(a);
        try board.postBounty(
            BountyBoard.Mode.AutoGrade, bytes32(0), METRIC, address(stock), reward, uint64(block.timestamp + 2 days)
        ) returns (uint256 id) {
            bountyIds.push(id);
        } catch {
            // insufficient TICKET for burn etc. — reclaim ghost accounting
            ghostStockIntoSystem -= reward;
        }
    }

    function postJudge(uint256 actorSeed, uint256 rewardSeed) public {
        address a = _actor(actorSeed);
        uint256 reward = bound(rewardSeed, 1e18, 50e18);
        stock.mint(a, reward);
        ghostStockIntoSystem += reward;
        vm.prank(a);
        try board.postBounty(
            BountyBoard.Mode.PosterJudge, bytes32(0), METRIC, address(stock), reward, uint64(block.timestamp + 2 days)
        ) returns (uint256 id) {
            bountyIds.push(id);
        } catch {
            ghostStockIntoSystem -= reward;
        }
    }

    // ------------------------------------------------------------- enter
    function enter(uint256 idSeed, uint256 actorSeed) public {
        if (bountyIds.length == 0) return;
        uint256 id = bountyIds[idSeed % bountyIds.length];
        address a = _actor(actorSeed);
        vm.prank(a);
        try board.enter(id) {
            if (!entered[id][a]) {
                entered[id][a] = true;
                entrants[id].push(a);
            }
        } catch {}
    }

    // ------------------------------------------------- finalize / select
    function finalizeAuto(uint256 idSeed) public {
        if (bountyIds.length == 0) return;
        uint256 id = bountyIds[idSeed % bountyIds.length];
        BountyBoard.Bounty memory b = board.getBounty(id);
        if (b.mode != BountyBoard.Mode.AutoGrade || b.state != BountyBoard.State.Open) return;
        if (entrants[id].length == 0) return;
        if (block.timestamp < b.deadline) vm.warp(uint256(b.deadline) + 1);

        address[] memory w = new address[](1);
        w[0] = entrants[id][0];
        uint256[] memory wt = new uint256[](1);
        wt[0] = 10_000;
        BountyBoard.Attestation memory att = BountyBoard.Attestation({
            bountyId: id,
            metricHash: METRIC,
            winners: w,
            weightsBps: wt,
            nonce: b.attestNonce,
            expiry: block.timestamp + 1 days
        });
        bytes memory sig = _sign(att);
        try board.finalize(id, att, sig) {} catch {}
    }

    function selectJudge(uint256 idSeed) public {
        if (bountyIds.length == 0) return;
        uint256 id = bountyIds[idSeed % bountyIds.length];
        BountyBoard.Bounty memory b = board.getBounty(id);
        if (b.mode != BountyBoard.Mode.PosterJudge || b.state != BountyBoard.State.Open) return;
        if (entrants[id].length == 0) return;
        vm.prank(b.poster);
        try board.selectWinner(id, entrants[id][0]) {} catch {}
    }

    // ------------------------------------------------------------- settle
    function settle(uint256 idSeed) public {
        if (bountyIds.length == 0) return;
        uint256 id = bountyIds[idSeed % bountyIds.length];
        BountyBoard.Bounty memory b = board.getBounty(id);
        if (b.state != BountyBoard.State.Finalized && b.state != BountyBoard.State.Selected) return;
        if (block.timestamp < b.settleAfter) vm.warp(uint256(b.settleAfter) + 1);

        uint256 outBefore = stock.balanceOf(address(board));
        try board.settle(id) {
            uint256 vaultGain = 0; // rake goes to vault (stays in system)
            uint256 outAfter = stock.balanceOf(address(board));
            // winner share left the system (board balance drop minus rake-to-vault).
            // rake stays in vault, so only the winner portion counts as "out".
            uint256 rake = b.rewardAmount * b.gmvRakeBps / 10_000;
            uint256 moved = outBefore - outAfter;
            if (moved > rake + vaultGain) ghostStockOut += (moved - rake);
        } catch {}
    }

    // ------------------------------------------------- revenue + distribute
    function revenue(uint256 amtSeed) public {
        uint256 amt = bound(amtSeed, 1e18, 100e18);
        stock.mint(address(router), amt);
        ghostStockIntoSystem += amt;
        try router.distribute(address(stock)) {} catch {}
    }

    // ------------------------------------------------------------- staking
    function stake(uint256 actorSeed, uint256 amtSeed, uint256 lockSeed) public {
        address a = _actor(actorSeed);
        uint256 amt = bound(amtSeed, 1e18, 1000e18);
        uint64 lock = uint64(bound(lockSeed, 0, staking.maxLock()));
        vm.prank(a);
        try staking.stake(amt, lock) {} catch {}
    }

    function claim(uint256 actorSeed) public {
        address a = _actor(actorSeed);
        uint256 before = stock.balanceOf(a);
        vm.prank(a);
        try staking.claim(address(stock)) {
            ghostStockOut += stock.balanceOf(a) - before;
        } catch {}
    }

    function requestUnstake(uint256 actorSeed) public {
        address a = _actor(actorSeed);
        vm.prank(a);
        try staking.requestUnstake() {} catch {}
    }

    function emergencyExit(uint256 actorSeed) public {
        address a = _actor(actorSeed);
        vm.prank(a);
        try staking.emergencyExit() {} catch {}
    }

    function warp(uint256 s) public {
        vm.warp(block.timestamp + bound(s, 1 hours, 10 days));
    }

    // --------------------------------------------------------------- helpers
    function bountyCount() external view returns (uint256) {
        return bountyIds.length;
    }

    function _sign(BountyBoard.Attestation memory att) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTEST_TYPEHASH,
                att.bountyId,
                att.metricHash,
                keccak256(abi.encodePacked(att.winners)),
                keccak256(abi.encodePacked(att.weightsBps)),
                att.nonce,
                att.expiry
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("AgentBountyBoard")),
                keccak256(bytes("1")),
                block.chainid,
                address(board)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(graderPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
