// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title $TICKET
/// @notice ERC-20 for the agent bounty board. Full supply is minted at genesis to a
///         single `genesisRecipient` — the pons fair-mint launcher (kept behind a clean
///         adapter boundary, see IPonsFairMint). There is no further minting: supply is
///         fixed at genesis and can only ever shrink via burn-to-post and buyback-burn.
/// @dev    Burnable (ERC20Burnable: burn + burnFrom) powers both deflation sinks.
///         Permit is included so agents/posters can approve gaslessly.
contract TICKET is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice The address that received the entire genesis supply (the pons launcher).
    address public immutable genesisRecipient;

    /// @notice The fixed genesis supply.
    uint256 public immutable genesisSupply;

    /// @param name_             token name
    /// @param symbol_           token symbol
    /// @param genesisSupply_    total supply minted once at construction
    /// @param genesisRecipient_ receiver of the full supply (pons fair-mint vault)
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 genesisSupply_,
        address genesisRecipient_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        require(genesisRecipient_ != address(0), "TICKET: zero recipient");
        require(genesisSupply_ > 0, "TICKET: zero supply");
        genesisRecipient = genesisRecipient_;
        genesisSupply = genesisSupply_;
        _mint(genesisRecipient_, genesisSupply_);
    }
}
