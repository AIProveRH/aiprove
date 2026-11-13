// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStockVault
/// @notice Treasury that holds tokenized-stock ERC-20s (and $TICKET) with a hard
///         solvency gate: it never releases more of a token than it currently holds.
interface IStockVault {
    /// @notice Live proof-of-reserves: the vault's on-chain balance of `token`.
    function reserves(address token) external view returns (uint256);

    /// @notice Release `amount` of `token` to `to`. MUST revert if amount > reserves.
    /// @dev Callable only by authorized spenders (FeeRouter / Staking / BountyBoard).
    function releaseTo(address token, address to, uint256 amount) external;
}
