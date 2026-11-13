// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {PayoutModule} from "../src/PayoutModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @notice Oracle guards: allowlist, zero, stale, incomplete-round, deviation.
contract OracleTest is Base {
    function test_happyQuote() public view {
        // 10 TSLA @ $100 = $1000 ; ticket=$1 → 1000 TICKET (1x multiplier)
        assertEq(payout.quoteStockToTicket(address(stock), 10e18), 1000e18);
        // $1000 of TICKET buys back 10 TSLA
        assertEq(payout.quoteTicketToStock(address(stock), 1000e18), 10e18);
    }

    function test_notAllowlisted_reverts() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        vm.expectRevert(abi.encodeWithSelector(PayoutModule.NotAllowed.selector, address(rogue)));
        payout.price1e18(address(rogue));
    }

    function test_zeroPrice_reverts() public {
        feed.setAnswer(0);
        vm.expectRevert(PayoutModule.ZeroPrice.selector);
        payout.price1e18(address(stock));
    }

    function test_negativePrice_reverts() public {
        feed.setAnswer(-1);
        vm.expectRevert(PayoutModule.ZeroPrice.selector);
        payout.price1e18(address(stock));
    }

    function test_stalePrice_reverts() public {
        // move time forward beyond maxStaleness (1h) without a feed update
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        payout.price1e18(address(stock));
    }

    function test_incompleteRound_reverts() public {
        // answeredInRound < roundId
        feed.setRound(100e8, block.timestamp, 10, 9);
        vm.expectRevert(PayoutModule.IncompleteRound.selector);
        payout.price1e18(address(stock));
    }

    function test_deviation_reverts() public {
        // anchor is $100, maxDeviation 10% → $120 is out of band
        feed.setAnswer(120e8);
        vm.expectRevert();
        payout.price1e18(address(stock));
    }

    function test_deviation_withinBand_ok() public {
        feed.setAnswer(109e8); // +9% < 10%
        uint256 p = payout.price1e18(address(stock));
        assertEq(p, 109e18);
    }

    function test_multiplierHaircut() public {
        // set a 90% multiplier (10% haircut) on payouts
        vm.prank(owner);
        payout.setFeed(address(stock), IAggregatorV3(address(feed)), 1 hours, 1000, 9000);
        assertEq(payout.quoteStockToTicket(address(stock), 10e18), 900e18);
    }
}
