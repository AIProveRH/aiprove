// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBuybackExecutor} from "../../src/interfaces/IBuybackExecutor.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Mock buyback executor. Simulates swapping received stock → $TICKET and
///         burning it: burns `amount * rate / 1e18` of its own pre-funded $TICKET stash.
contract MockBuybackExecutor is IBuybackExecutor {
    ERC20Burnable public immutable ticket;
    uint256 public rate = 1e18; // TICKET burned per 1 unit of stock (1e18 = 1:1)

    constructor(ERC20Burnable ticket_) {
        ticket = ticket_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function buybackAndBurn(address, uint256 amount) external override {
        uint256 toBurn = (amount * rate) / 1e18;
        uint256 bal = ticket.balanceOf(address(this));
        if (toBurn > bal) toBurn = bal;
        ticket.burn(toBurn);
    }
}
