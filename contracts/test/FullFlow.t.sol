// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {BountyBoard} from "../src/BountyBoard.sol";

/// @notice End-to-end happy paths for BOTH verification lanes.
contract FullFlowTest is Base {
    bytes32 constant METRIC = keccak256("backtest-pnl");
    bytes32 constant CAT = keccak256("trading");

    function _postAutoGrade(uint256 reward) internal returns (uint256 id) {
        _mintStockTo(poster, reward);
        vm.startPrank(poster);
        ticket.approve(address(board), type(uint256).max);
        stock.approve(address(board), type(uint256).max);
        id = board.postBounty(
            BountyBoard.Mode.AutoGrade, CAT, METRIC, address(stock), reward, uint64(block.timestamp + 3 days)
        );
        vm.stopPrank();
    }

    // -------------------------------------------------- LANE A: AutoGrade
    function test_AutoGrade_fullFlow() public {
        uint256 reward = 10e18; // 10 TSLA @ $100 = $1000 = 1000 TICKET value
        uint256 supplyBefore = ticket.totalSupply();

        uint256 id = _postAutoGrade(reward);

        // burn-to-post: 4% of 1000 TICKET value = 40 TICKET burned
        assertEq(supplyBefore - ticket.totalSupply(), 40e18, "burn-to-post amount");
        assertEq(stock.balanceOf(address(board)), reward, "reward escrowed");
        assertEq(board.escrowed(address(stock)), reward, "escrow ghost");

        // free entry
        vm.prank(alice);
        board.enter(id);
        vm.prank(bob);
        board.enter(id);

        // submissions (provenance)
        vm.prank(alice);
        board.submit(id, keccak256("repo-a"), keccak256("transcript-a"));
        vm.prank(bob);
        board.submit(id, keccak256("repo-b"), keccak256("transcript-b"));

        // grading happens after deadline
        vm.warp(block.timestamp + 3 days + 1);

        BountyBoard.Attestation memory att =
            _attestation(id, METRIC, _arr(alice, bob), _u(7000, 3000));
        bytes memory sig = _signAttestation(att, graderPk);

        board.finalize(id, att, sig);
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Finalized));

        // cannot settle during challenge window
        vm.expectRevert(BountyBoard.WindowOpen.selector);
        board.settle(id);

        vm.warp(block.timestamp + 2 days + 1); // past challenge window
        board.settle(id);

        // rake = 4% * 10 = 0.4 ; payout 9.6 ; alice 70% = 6.72 ; bob remainder 2.88
        assertEq(stock.balanceOf(address(vault)), 0.4e18, "GMV rake to treasury");
        assertEq(stock.balanceOf(alice), 6.72e18, "alice payout");
        assertEq(stock.balanceOf(bob), 2.88e18, "bob payout");
        assertEq(board.escrowed(address(stock)), 0, "escrow cleared");
        assertEq(stock.balanceOf(address(board)), 0, "board drained");
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Settled));
    }

    // -------------------------------------------------- LANE B: PosterJudge
    function test_PosterJudge_cleanSettle_bondReturned() public {
        uint256 reward = 10e18;
        _mintStockTo(poster, reward);
        uint256 posterTicketBefore = ticket.balanceOf(poster);

        vm.startPrank(poster);
        ticket.approve(address(board), type(uint256).max);
        stock.approve(address(board), type(uint256).max);
        uint256 id = board.postBounty(
            BountyBoard.Mode.PosterJudge,
            keccak256("design"),
            METRIC,
            address(stock),
            reward,
            uint64(block.timestamp + 3 days)
        );
        vm.stopPrank();

        // bond = 10% of 1000 TICKET value = 100 TICKET ; burn = 40 TICKET
        assertEq(board.getBounty(id).bondAmount, 100e18, "bond sized");
        assertEq(posterTicketBefore - ticket.balanceOf(poster), 140e18, "burn + bond pulled");
        assertEq(board.escrowed(address(ticket)), 100e18, "bond escrowed");

        vm.prank(alice);
        board.enter(id);
        vm.prank(bob);
        board.enter(id);

        vm.prank(poster);
        board.selectWinner(id, alice);
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Selected));

        // undisputed: settle after dispute window
        vm.warp(block.timestamp + 2 days + 1);
        board.settle(id);

        assertEq(stock.balanceOf(alice), 9.6e18, "winner payout");
        assertEq(stock.balanceOf(address(vault)), 0.4e18, "rake to treasury");
        // bond returned to poster
        assertEq(ticket.balanceOf(poster), posterTicketBefore - 40e18, "only burn lost, bond back");
        assertEq(board.escrowed(address(ticket)), 0, "bond escrow cleared");
    }

    function test_PosterJudge_dispute_arbiterResolve_slashBond() public {
        uint256 reward = 10e18;
        _mintStockTo(poster, reward);

        vm.startPrank(poster);
        ticket.approve(address(board), type(uint256).max);
        stock.approve(address(board), type(uint256).max);
        uint256 id = board.postBounty(
            BountyBoard.Mode.PosterJudge,
            keccak256("design"),
            METRIC,
            address(stock),
            reward,
            uint64(block.timestamp + 3 days)
        );
        vm.stopPrank();

        vm.prank(alice);
        board.enter(id);
        vm.prank(bob);
        board.enter(id);

        // poster picks bob (the "wrong" winner)
        vm.prank(poster);
        board.selectWinner(id, bob);

        // alice (a valid entrant) disputes within window
        vm.prank(alice);
        board.dispute(id);
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Disputed));

        // arbiter overrides to alice and SLASHES the poster bond
        vm.prank(arbiter);
        board.arbiterResolve(id, alice, true);

        board.settle(id); // immediately settleable

        assertEq(stock.balanceOf(alice), 9.6e18, "arbiter winner paid");
        assertEq(stock.balanceOf(bob), 0, "rejected pick gets nothing");
        // slashed bond -> treasury (100 TICKET) + rake (0.4 stock)
        assertEq(ticket.balanceOf(address(vault)), 100e18, "bond slashed to treasury");
        assertEq(stock.balanceOf(address(vault)), 0.4e18, "rake to treasury");
    }

    function test_PosterJudge_ghostPoster_arbiterResolves() public {
        uint256 reward = 10e18;
        _mintStockTo(poster, reward);
        vm.startPrank(poster);
        ticket.approve(address(board), type(uint256).max);
        stock.approve(address(board), type(uint256).max);
        uint256 id = board.postBounty(
            BountyBoard.Mode.PosterJudge,
            keccak256("design"),
            METRIC,
            address(stock),
            reward,
            uint64(block.timestamp + 3 days)
        );
        vm.stopPrank();

        vm.prank(alice);
        board.enter(id);

        // poster never selects; past deadline + grace
        vm.warp(block.timestamp + 3 days + 7 days + 1);

        vm.prank(arbiter);
        board.arbiterResolve(id, alice, true); // ghosted → slash

        board.settle(id);
        assertEq(stock.balanceOf(alice), 9.6e18, "entrant paid despite ghost");
        assertEq(ticket.balanceOf(address(vault)), 100e18, "ghost bond slashed");
    }
}
