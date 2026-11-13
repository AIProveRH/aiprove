// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {BountyBoard} from "../src/BountyBoard.sol";
import {StockVault} from "../src/StockVault.sol";

contract AccessControlTest is Base {
    bytes32 constant METRIC = keccak256("m");
    bytes32 constant CAT = keccak256("c");

    function _post(BountyBoard.Mode mode) internal returns (uint256 id) {
        _mintStockTo(poster, 10e18);
        vm.startPrank(poster);
        ticket.approve(address(board), type(uint256).max);
        stock.approve(address(board), type(uint256).max);
        id = board.postBounty(mode, CAT, METRIC, address(stock), 10e18, uint64(block.timestamp + 3 days));
        vm.stopPrank();
    }

    // --------------------------------------------------- grader signer gating
    function test_finalize_badSigner_reverts() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);

        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(alice), _u(10000));
        bytes memory sig = _signAttestation(att, 0xBEEF); // wrong key
        vm.expectRevert(BountyBoard.BadSignature.selector);
        board.finalize(id, att, sig);
    }

    function test_finalize_whenPaused_reverts() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(owner);
        board.setGraderPaused(true);

        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(alice), _u(10000));
        bytes memory sig = _signAttestation(att, graderPk);
        vm.expectRevert(BountyBoard.GraderPausedErr.selector);
        board.finalize(id, att, sig);
    }

    function test_rotateSigner_newKeyWorks() public {
        uint256 newPk = 0xC0FFEE;
        vm.prank(owner);
        board.setGraderSigner(vm.addr(newPk));

        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(alice), _u(10000));
        // old key now rejected
        vm.expectRevert(BountyBoard.BadSignature.selector);
        board.finalize(id, att, _signAttestation(att, graderPk));
        // new key accepted
        board.finalize(id, att, _signAttestation(att, newPk));
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Finalized));
    }

    function test_attestation_wrongMetric_reverts() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        BountyBoard.Attestation memory att = _attestation(id, keccak256("WRONG"), _arr(alice), _u(10000));
        vm.expectRevert(BountyBoard.BadAttestation.selector);
        board.finalize(id, att, _signAttestation(att, graderPk));
    }

    function test_attestation_nonEntrantWinner_reverts() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(bob), _u(10000)); // bob never entered
        vm.expectRevert(BountyBoard.BadAttestation.selector);
        board.finalize(id, att, _signAttestation(att, graderPk));
    }

    function test_attestation_weightsNot100_reverts() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.prank(bob);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(alice, bob), _u(6000, 3000));
        vm.expectRevert(BountyBoard.BadAttestation.selector);
        board.finalize(id, att, _signAttestation(att, graderPk));
    }

    // ------------------------------------------------------------- anti-rug
    function test_posterCannotCancel_afterEntries() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.prank(poster);
        vm.expectRevert(BountyBoard.EntriesExist.selector);
        board.cancelBounty(id);
    }

    function test_posterCanCancel_beforeEntries() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        uint256 balBefore = stock.balanceOf(poster);
        vm.prank(poster);
        board.cancelBounty(id);
        assertEq(stock.balanceOf(poster), balBefore + 10e18, "reward refunded, no entries");
    }

    function test_nonPosterCannotCancel() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        vm.expectRevert(BountyBoard.NotPoster.selector);
        board.cancelBounty(id);
    }

    function test_refundExpired_onlyAfterGrace_autoGradeOnly() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id); // entries exist, but grader never attests
        // too early
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(BountyBoard.WindowOpen.selector);
        board.refundExpired(id);
        // after grace → poster recovers reward (grader outage, not a rug)
        vm.warp(block.timestamp + 7 days);
        uint256 balBefore = stock.balanceOf(poster);
        board.refundExpired(id);
        assertEq(stock.balanceOf(poster), balBefore + 10e18);
    }

    function test_refundExpired_posterJudge_reverts() public {
        uint256 id = _post(BountyBoard.Mode.PosterJudge);
        vm.warp(block.timestamp + 3 days + 7 days + 1);
        vm.expectRevert(BountyBoard.WrongMode.selector);
        board.refundExpired(id);
    }

    // ------------------------------------------------------- role gating
    function test_selectWinner_onlyPoster() public {
        uint256 id = _post(BountyBoard.Mode.PosterJudge);
        vm.prank(alice);
        board.enter(id);
        vm.prank(bob);
        vm.expectRevert(BountyBoard.NotPoster.selector);
        board.selectWinner(id, alice);
    }

    function test_dispute_onlyEntrant() public {
        uint256 id = _post(BountyBoard.Mode.PosterJudge);
        vm.prank(alice);
        board.enter(id);
        vm.prank(poster);
        board.selectWinner(id, alice);
        // carol never entered
        vm.prank(carol);
        vm.expectRevert(BountyBoard.NotEntrant.selector);
        board.dispute(id);
    }

    function test_arbiterResolve_onlyArbiter() public {
        uint256 id = _post(BountyBoard.Mode.PosterJudge);
        vm.prank(alice);
        board.enter(id);
        vm.prank(poster);
        board.selectWinner(id, alice);
        vm.prank(alice);
        board.dispute(id);
        vm.prank(bob);
        vm.expectRevert(BountyBoard.NotArbiter.selector);
        board.arbiterResolve(id, alice, true);
    }

    function test_voidAttestation_onlyArbiter_duringWindow() public {
        uint256 id = _post(BountyBoard.Mode.AutoGrade);
        vm.prank(alice);
        board.enter(id);
        vm.warp(block.timestamp + 3 days + 1);
        BountyBoard.Attestation memory att = _attestation(id, METRIC, _arr(alice), _u(10000));
        board.finalize(id, att, _signAttestation(att, graderPk));

        vm.prank(bob);
        vm.expectRevert(BountyBoard.NotArbiter.selector);
        board.voidAttestation(id);

        // arbiter voids → reopens, nonce bumped so the old sig is dead
        vm.prank(arbiter);
        board.voidAttestation(id);
        assertEq(uint8(board.getBounty(id).state), uint8(BountyBoard.State.Open));
        assertEq(board.getBounty(id).attestNonce, 1);

        // old sig (nonce 0) now invalid
        vm.expectRevert(BountyBoard.BadAttestation.selector);
        board.finalize(id, att, _signAttestation(att, graderPk));
    }

    function test_setParams_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        board.setParams(100, 1e18, 100, 1e18, 100);
        vm.prank(owner);
        board.setParams(100, 1e18, 100, 1e18, 100);
        assertEq(board.burnBps(), 100);
    }

    function test_vaultReleaseTo_onlySpender() public {
        _mintStockTo(address(vault), 5e18);
        vm.prank(alice);
        vm.expectRevert(StockVault.NotSpender.selector);
        vault.releaseTo(address(stock), alice, 1e18);
    }
}
