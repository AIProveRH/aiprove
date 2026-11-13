// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStaking
/// @notice Dividend sink: the FeeRouter notifies the staking module of a dividend in
///         `token` (tokens themselves are parked in the Treasury; stakers pull-claim).
interface IStaking {
    function notifyDividend(address token, uint256 amount) external;
}
