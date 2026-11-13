// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TICKET} from "../src/TICKET.sol";
import {StockVault} from "../src/StockVault.sol";
import {PayoutModule} from "../src/PayoutModule.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {Staking} from "../src/Staking.sol";
import {BountyBoard} from "../src/BountyBoard.sol";
import {IStockVault} from "../src/interfaces/IStockVault.sol";
import {IPayoutModule} from "../src/interfaces/IPayoutModule.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {IBuybackExecutor} from "../src/interfaces/IBuybackExecutor.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockBuybackExecutor} from "./mocks/MockBuybackExecutor.sol";

/// @notice Deploys + wires the whole system for tests, with an EIP-712 grader signer.
contract Base is Test {
    // actors
    address owner = makeAddr("owner");
    address arbiter = makeAddr("arbiter");
    uint256 graderPk = 0xA11CE;
    address graderSigner;

    address poster = makeAddr("poster");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    // system
    TICKET ticket;
    StockVault vault;
    PayoutModule payout;
    FeeRouter router;
    Staking staking;
    BountyBoard board;

    // mocks
    MockERC20 stock; // tokenized stock, 18 dec
    MockAggregator feed; // $100, 8 dec
    MockBuybackExecutor executor;

    uint256 constant GENESIS = 1_000_000_000e18;

    bytes32 constant ATTEST_TYPEHASH = keccak256(
        "Attestation(uint256 bountyId,bytes32 metricHash,address[] winners,uint256[] weightsBps,uint256 nonce,uint256 expiry)"
    );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public virtual {
        graderSigner = vm.addr(graderPk);

        // TICKET: full supply minted to this test contract (acts as the pons launcher).
        ticket = new TICKET("Ticket", "TICKET", GENESIS, address(this));

        vault = new StockVault(owner);
        payout = new PayoutModule(owner, 1e18); // 1 TICKET = $1
        router = new FeeRouter(owner, ERC20Burnable(address(ticket)), address(vault));
        staking = new Staking(owner, IERC20(address(ticket)), IStockVault(address(vault)));
        board = new BountyBoard(
            owner,
            ERC20Burnable(address(ticket)),
            IPayoutModule(address(payout)),
            address(vault),
            graderSigner,
            arbiter
        );

        // mock stock + feed @ $100 (8 decimals)
        stock = new MockERC20("Tesla", "TSLA", 18);
        feed = new MockAggregator(8, 100e8);
        executor = new MockBuybackExecutor(ERC20Burnable(address(ticket)));

        vm.startPrank(owner);
        payout.setFeed(address(stock), IAggregatorV3(address(feed)), 1 hours, 1000, 10_000); // 10% dev, 1x
        payout.setAnchor(address(stock), 100e18);
        // authorize spenders on the vault
        vault.setSpender(address(staking), true);
        vault.setSpender(address(router), true);
        vault.setSpender(address(board), true);
        // staking distributor = router
        staking.setDistributor(address(router));
        router.setWiring(address(vault), IStaking(address(staking)), IBuybackExecutor(address(executor)));
        vm.stopPrank();

        // fund actors with TICKET
        ticket.transfer(poster, 10_000_000e18);
        ticket.transfer(alice, 10_000_000e18);
        ticket.transfer(bob, 10_000_000e18);
        ticket.transfer(carol, 10_000_000e18);
    }

    // ------------------------------------------------------- helpers
    function _mintStockTo(address to, uint256 amt) internal {
        stock.mint(to, amt);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("AgentBountyBoard")),
                keccak256(bytes("1")),
                block.chainid,
                address(board)
            )
        );
    }

    function _signAttestation(BountyBoard.Attestation memory att, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attestation(uint256 id, bytes32 metric, address[] memory winners, uint256[] memory weights)
        internal
        view
        returns (BountyBoard.Attestation memory)
    {
        return BountyBoard.Attestation({
            bountyId: id,
            metricHash: metric,
            winners: winners,
            weightsBps: weights,
            nonce: 0,
            expiry: block.timestamp + 1 days
        });
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _arr(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
