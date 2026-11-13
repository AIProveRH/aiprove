// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TICKET} from "../src/TICKET.sol";
import {PayoutModule} from "../src/PayoutModule.sol";
import {BountyBoard} from "../src/BountyBoard.sol";
import {IPayoutModule} from "../src/interfaces/IPayoutModule.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice LOCAL-ONLY deploy for the end-to-end FORECAST proof.
///         Deploys the minimal slice needed for an AutoGrade forecast bounty paid
///         in $TICKET: TICKET + PayoutModule (constructor dep; unused when the
///         reward token is TICKET) + BountyBoard. Funds the poster + entrants.
///
///         Intended for a throwaway local anvil / forge-test node ONLY. Addresses
///         (grader signer, treasury, arbiter, actors) come from env with anvil
///         defaults as fallback, so run.sh wires the grader key's address in.
contract DeployLocal is Script {
    uint256 constant GENESIS = 1_000_000_000e18; // 1B TICKET
    uint256 constant FUND = 10_000_000e18; // per funded actor

    function run() external {
        // deployer = broadcaster = genesis TICKET holder
        address deployer = msg.sender;

        address graderSigner = vm.envOr("GRADER_SIGNER", 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720); // anvil[9]
        address treasury = vm.envOr("TREASURY", 0x976EA74026E726554dB657fA54763abd0C3a0aa9); // anvil[6]
        address arbiter = vm.envOr("ARBITER", 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955); // anvil[7]
        address poster = vm.envOr("POSTER", 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65); // anvil[4]
        address alice = vm.envOr("ALICE", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8); // anvil[1]
        address bob = vm.envOr("BOB", 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC); // anvil[2]
        address carol = vm.envOr("CAROL", 0x90F79bf6EB2c4f870365E785982E1f101E93b906); // anvil[3]

        vm.startBroadcast();

        TICKET ticket = new TICKET("Ticket", "TICKET", GENESIS, deployer);
        PayoutModule payout = new PayoutModule(deployer, 1e18); // 1 TICKET = $1 (unused for TICKET reward)
        BountyBoard board = new BountyBoard(
            deployer,
            ERC20Burnable(address(ticket)),
            IPayoutModule(address(payout)),
            treasury,
            graderSigner,
            arbiter
        );

        // fund poster + entrants in TICKET (reward + burn-to-post come from poster)
        ticket.transfer(poster, FUND);
        ticket.transfer(alice, FUND);
        ticket.transfer(bob, FUND);
        ticket.transfer(carol, FUND);

        vm.stopBroadcast();

        console2.log("TICKET", address(ticket));
        console2.log("PAYOUT", address(payout));
        console2.log("BOARD", address(board));
        console2.log("TREASURY", treasury);
        console2.log("GRADER_SIGNER", graderSigner);
    }
}
