// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FeeRouter} from "../src/FeeRouter.sol";

contract FeeRouterTest is Base {
    function setUp() public override {
        super.setUp();
        // pre-fund the buyback executor with a TICKET stash it can burn
        ticket.transfer(address(executor), 1_000_000e18);
        // alice stakes so dividends have weight to credit
        uint64 maxLock = staking.maxLock();
        vm.prank(alice);
        ticket.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(100e18, maxLock);
    }

    function test_split_40_35_25_stockRevenue() public {
        // 1000 units of stock revenue arrives at the router
        _mintStockTo(address(router), 1000e18);
        uint256 supplyBefore = ticket.totalSupply();

        router.distribute(address(stock));

        // 40% buyback-burn: 400 stock → executor burns 400 TICKET (1:1 rate)
        assertEq(supplyBefore - ticket.totalSupply(), 400e18, "buyback-burn reduced TICKET supply");
        // 35% dividends + 25% platform both land in the treasury (stock)
        assertEq(stock.balanceOf(address(vault)), 600e18, "dividends + platform to treasury");
        // dividends (350) credited to the sole staker (sub-wei accumulator dust tolerated)
        assertApproxEqAbs(staking.pending(alice, address(stock)), 350e18, 1e6, "staker dividend credited");
        // router fully drained
        assertEq(stock.balanceOf(address(router)), 0, "router drained");
    }

    function test_ticketRevenue_buybackBurnsDirectly() public {
        // when the fee token IS TICKET, the buyback leg burns it directly (no executor)
        ticket.transfer(address(router), 1000e18);
        uint256 supplyBefore = ticket.totalSupply();

        router.distribute(address(ticket));

        assertEq(supplyBefore - ticket.totalSupply(), 400e18, "40% TICKET burned directly");
        assertEq(ticket.balanceOf(address(vault)), 600e18, "dividends+platform TICKET to treasury");
        assertApproxEqAbs(staking.pending(alice, address(ticket)), 350e18, 1e6, "TICKET dividend credited");
    }

    function test_setSplit_mustSumTo100() public {
        vm.prank(owner);
        vm.expectRevert(FeeRouter.SplitNot100.selector);
        router.setSplit(4000, 3000, 2000); // 90%

        vm.prank(owner);
        router.setSplit(5000, 3000, 2000); // 100%
        assertEq(router.buybackBps(), 5000);
    }

    function test_setSplit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setSplit(4000, 3500, 2500);
    }

    function test_distribute_noDustLoss() public {
        // odd amount → remainder folded into platform slice, nothing stranded
        _mintStockTo(address(router), 1001e18 + 7);
        router.distribute(address(stock));
        assertEq(stock.balanceOf(address(router)), 0, "no residual dust left in router");
    }
}
