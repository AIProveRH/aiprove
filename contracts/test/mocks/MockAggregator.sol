// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Mock Chainlink feed. Lets tests drive price, staleness and round state.
contract MockAggregator is IAggregatorV3 {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 d, int256 initialAnswer) {
        decimals = d;
        answer = initialAnswer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId += 1;
        answeredInRound = roundId;
    }

    /// @notice Set a raw round (to simulate stale / incomplete rounds).
    function setRound(int256 a, uint256 updatedAt_, uint80 roundId_, uint80 answeredInRound_) external {
        answer = a;
        updatedAt = updatedAt_;
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
