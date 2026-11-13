// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3
/// @notice Minimal Chainlink-style price feed interface. The real Chainlink
///         aggregator address slots in later; a mock implements this for tests.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
