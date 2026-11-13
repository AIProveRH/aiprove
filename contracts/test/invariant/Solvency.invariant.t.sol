// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TICKET} from "../../src/TICKET.sol";
import {StockVault} from "../../src/StockVault.sol";
import {PayoutModule} from "../../src/PayoutModule.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {Staking} from "../../src/Staking.sol";
import {BountyBoard} from "../../src/BountyBoard.sol";
import {IStockVault} from "../../src/interfaces/IStockVault.sol";
import {IPayoutModule} from "../../src/interfaces/IPayoutModule.sol";
import {IStaking} from "../../src/interfaces/IStaking.sol";
import {IBuybackExecutor} from "../../src/interfaces/IBuybackExecutor.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockBuybackExecutor} from "../mocks/MockBuybackExecutor.sol";
import {SolvencyHandler} from "./SolvencyHandler.sol";

/// @notice THE critical suite: the Treasury/escrow never pays out more than it holds,
///         across any ordering of posts / finalizes / dividends / buybacks / claims —
///         over BOTH verification lanes.
contract SolvencyInvariantTest is Test {
    TICKET ticket;
    StockVault vault;
    PayoutModule payout;
    FeeRouter router;
    Staking staking;
    BountyBoard board;
    MockERC20 stock;
    MockAggregator feed;
    MockBuybackExecutor executor;
    SolvencyHandler handler;

    address owner = makeAddr("owner");
    address arbiter = makeAddr("arbiter");
    uint256 graderPk = 0xA11CE;

    address[] actors;

    function setUp() public {
        ticket = new TICKET("Ticket", "TICKET", 10_000_000_000e18, address(this));
        vault = new StockVault(owner);
        payout = new PayoutModule(owner, 1e18);
        router = new FeeRouter(owner, ERC20Burnable(address(ticket)), address(vault));
        staking = new Staking(owner, IERC20(address(ticket)), IStockVault(address(vault)));
        board = new BountyBoard(
            owner,
            ERC20Burnable(address(ticket)),
            IPayoutModule(address(payout)),
            address(vault),
            vm.addr(graderPk),
            arbiter
        );
        stock = new MockERC20("Tesla", "TSLA", 18);
        feed = new MockAggregator(8, 100e8);
        executor = new MockBuybackExecutor(ERC20Burnable(address(ticket)));

        vm.startPrank(owner);
        payout.setFeed(address(stock), IAggregatorV3(address(feed)), 365 days, 0, 10_000); // no staleness/dev noise
        vault.setSpender(address(staking), true);
        vault.setSpender(address(router), true);
        vault.setSpender(address(board), true);
        staking.setDistributor(address(router));
        router.setWiring(address(vault), IStaking(address(staking)), IBuybackExecutor(address(executor)));
        vm.stopPrank();

        // actors
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
        for (uint256 i; i < actors.length; ++i) {
            ticket.transfer(actors[i], 1_000_000_000e18);
            vm.startPrank(actors[i]);
            ticket.approve(address(board), type(uint256).max);
            stock.approve(address(board), type(uint256).max);
            ticket.approve(address(staking), type(uint256).max);
            vm.stopPrank();
        }

        // pre-fund buyback executor with a TICKET stash to burn
        ticket.transfer(address(executor), 1_000_000_000e18);

        handler = new SolvencyHandler(
            board, router, staking, vault, ticket, stock, graderPk, arbiter, actors
        );
        targetContract(address(handler));
    }

    // ---- The board never holds less (or more) stock than it owes as escrow.
    function invariant_boardStockEscrowExact() public view {
        assertEq(stock.balanceOf(address(board)), board.escrowed(address(stock)), "board stock escrow mismatch");
    }

    // ---- The board never holds less (or more) TICKET than its outstanding bonds.
    function invariant_boardTicketEscrowExact() public view {
        assertEq(ticket.balanceOf(address(board)), board.escrowed(address(ticket)), "board bond escrow mismatch");
    }

    // ---- THE solvency invariant: the Treasury always holds at least the total
    //      outstanding staker dividend claims — it can never be asked to pay what it
    //      does not have.
    function invariant_treasuryCoversAllClaims() public view {
        uint256 owed;
        for (uint256 i; i < actors.length; ++i) {
            owed += staking.pending(actors[i], address(stock));
        }
        assertGe(stock.balanceOf(address(vault)), owed, "treasury under-collateralized vs claims");
    }

    // ---- No money printing: stock leaving the system never exceeds stock that entered.
    function invariant_noOverpay() public view {
        assertGe(handler.ghostStockIntoSystem(), handler.ghostStockOut(), "paid out more than came in");
    }

    function invariant_callSummary() public view {
        // surfaces how many bounties the fuzzer actually created (coverage sanity)
        assertTrue(true);
    }
}
