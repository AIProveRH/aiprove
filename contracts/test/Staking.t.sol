// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {Staking} from "../src/Staking.sol";

contract StakingTest is Base {
    uint64 MAXLOCK;

    function setUp() public override {
        super.setUp();
        MAXLOCK = staking.maxLock();
        // fund the treasury with stock so dividend claims are solvent
        _mintStockTo(address(vault), 1_000_000e18);
        // give actors approvals
        vm.prank(alice);
        ticket.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        ticket.approve(address(staking), type(uint256).max);
        vm.prank(carol);
        ticket.approve(address(staking), type(uint256).max);
    }

    function _notify(uint256 amount) internal {
        vm.prank(address(router));
        staking.notifyDividend(address(stock), amount);
    }

    // ------------------------------------- weight-by-stake (sybil neutrality)
    function test_sybilSplit_noAdvantage() public {
        // alice: one 100-TICKET stake. bob+carol: split 50/50. Same max lock.
        vm.prank(alice);
        staking.stake(100e18, MAXLOCK);
        vm.prank(bob);
        staking.stake(50e18, MAXLOCK);
        vm.prank(carol);
        staking.stake(50e18, MAXLOCK);

        _notify(600e18);

        uint256 aliceP = staking.pending(alice, address(stock));
        uint256 splitP = staking.pending(bob, address(stock)) + staking.pending(carol, address(stock));
        assertEq(aliceP, splitP, "split stake earns identical total - sybil pointless");
    }

    // --------------------------------------------------------- time-weighting
    function test_timeWeight_longerStakeEarnsMore() public {
        vm.prank(alice);
        staking.stake(100e18, MAXLOCK); // alice present for D1 and D2

        _notify(100e18); // D1 — only alice staked

        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        staking.stake(100e18, MAXLOCK); // bob joins after D1

        _notify(100e18); // D2 — both staked, equal weight

        uint256 aliceP = staking.pending(alice, address(stock));
        uint256 bobP = staking.pending(bob, address(stock));
        // accumulator carries sub-wei rounding dust (favors the vault); assert within 1e6
        assertApproxEqAbs(aliceP, 150e18, 1e6, "alice: all of D1 + half D2");
        assertApproxEqAbs(bobP, 50e18, 1e6, "bob: half of D2 only");
        assertGt(aliceP, bobP, "earlier/longer staker earns more");
    }

    // ------------------------------------------------------------- ve-boost 3x
    function test_veBoost_upTo3x() public {
        vm.prank(alice);
        staking.stake(100e18, 0); // 1x
        vm.prank(bob);
        staking.stake(100e18, MAXLOCK); // 3x

        assertEq(staking.boostFor(0), 10_000);
        assertEq(staking.boostFor(MAXLOCK), 30_000);

        _notify(400e18); // total weight 100 + 300 = 400
        assertEq(staking.pending(alice, address(stock)), 100e18, "1x share");
        assertEq(staking.pending(bob, address(stock)), 300e18, "3x share");
        assertEq(
            staking.pending(bob, address(stock)), 3 * staking.pending(alice, address(stock)), "exactly 3x"
        );
    }

    function test_veBoost_linearMidpoint() public {
        // half the max lock → 2x boost
        assertEq(staking.boostFor(MAXLOCK / 2), 20_000);
    }

    // --------------------------------------------------------------- cooldown
    function test_cooldownEnforced() public {
        vm.prank(alice);
        staking.stake(100e18, 0); // lock 0 → unlockable now

        vm.prank(alice);
        staking.requestUnstake();

        // withdraw before cooldown elapses reverts
        vm.prank(alice);
        vm.expectRevert(Staking.CooldownNotElapsed.selector);
        staking.withdraw();

        vm.warp(block.timestamp + 7 days);
        uint256 bal = ticket.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw();
        assertEq(ticket.balanceOf(alice), bal + 100e18, "principal returned after cooldown");
    }

    function test_cannotUnstakeWhileLocked() public {
        vm.prank(alice);
        staking.stake(100e18, MAXLOCK);
        vm.prank(alice);
        vm.expectRevert(Staking.Locked.selector);
        staking.requestUnstake();
    }

    function test_cooldownStopsEarning() public {
        vm.prank(alice);
        staking.stake(100e18, 0);
        vm.prank(bob);
        staking.stake(100e18, 0);

        vm.prank(alice);
        staking.requestUnstake(); // alice weight removed

        _notify(100e18); // only bob (weight 100) should earn
        assertEq(staking.pending(alice, address(stock)), 0, "cooldown account earns nothing");
        assertEq(staking.pending(bob, address(stock)), 100e18, "remaining staker takes all");
    }

    // -------------------------------------------------- claim pulls from vault
    function test_claim_pullsFromTreasury() public {
        vm.prank(alice);
        staking.stake(100e18, MAXLOCK);
        _notify(300e18);

        uint256 vaultBefore = stock.balanceOf(address(vault));
        vm.prank(alice);
        uint256 got = staking.claim(address(stock));
        assertEq(got, 300e18);
        assertEq(stock.balanceOf(alice), 300e18, "dividend received in stock");
        assertEq(stock.balanceOf(address(vault)), vaultBefore - 300e18, "pulled from treasury reserves");
        // double-claim yields nothing
        vm.prank(alice);
        assertEq(staking.claim(address(stock)), 0);
    }

    // ------------------------------ forfeiture of unvested rewards on exit
    function test_emergencyExit_forfeitsRewards_returnsPrincipal() public {
        vm.prank(alice);
        staking.stake(100e18, MAXLOCK);
        _notify(500e18);
        assertApproxEqAbs(staking.pending(alice, address(stock)), 500e18, 1e6, "accrued before exit");

        uint256 bal = ticket.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyExit(); // bypass lock + cooldown, forfeit rewards

        assertEq(ticket.balanceOf(alice), bal + 100e18, "principal always recoverable (non-custodial)");
        assertEq(staking.pending(alice, address(stock)), 0, "unvested rewards forfeited");
        vm.prank(alice);
        assertEq(staking.claim(address(stock)), 0, "nothing to claim after forfeit");
    }

    function test_bankedRewardsSurviveUnstake() public {
        vm.prank(alice);
        staking.stake(100e18, 0);
        _notify(200e18);
        vm.prank(alice);
        staking.requestUnstake(); // settles accrued into buffer
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        staking.withdraw();
        // banked dividend still claimable after an orderly exit
        vm.prank(alice);
        assertEq(staking.claim(address(stock)), 200e18, "orderly exit keeps earned dividends");
    }
}
