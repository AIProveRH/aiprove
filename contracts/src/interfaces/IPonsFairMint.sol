// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPonsFairMint
/// @notice Clean adapter boundary for the pons fair-mint launch. $TICKET mints its
///         full genesis supply to a `genesisRecipient` (the pons vault / launcher) at
///         construction. The real pons contracts are deployed separately and simply
///         become that recipient — nothing in this repo is hard-coupled to pons.
/// @dev Kept as an interface only so the production launcher can be type-checked
///      against it; TICKET itself does not call into pons.
interface IPonsFairMint {
    /// @notice The token being fair-minted.
    function token() external view returns (address);

    /// @notice Total supply handed to the launcher at genesis.
    function genesisSupply() external view returns (uint256);
}
