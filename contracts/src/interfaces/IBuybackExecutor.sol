// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IBuybackExecutor
/// @notice Stub boundary for the buyback-burn leg. Given stock tokens, the executor
///         swaps them to $TICKET on-market and burns the proceeds. The real DEX/router
///         wiring slots in later; a mock implements this for tests.
interface IBuybackExecutor {
    /// @notice Pull `amount` of `stockToken` (already transferred to the executor) and
    ///         buy-back + burn $TICKET with it.
    function buybackAndBurn(address stockToken, uint256 amount) external;
}
