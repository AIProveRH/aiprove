// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStockVault} from "./interfaces/IStockVault.sol";

/// @title Staking
/// @notice Non-custodial $TICKET staking with ve-lock boost (up to 3x), time-weighted
///         reward accrual, weight-by-stake distribution (sybil-neutral), a 7-day unstake
///         cooldown, and forfeiture of unvested rewards on early (emergency) exit.
///         Dividends are paid in stock, pulled from the solvency-gated Treasury.
///
/// @dev Reward math is a multi-token MasterChef accumulator. Distribution is strictly
///      LINEAR in `weight`, so splitting a stake across N accounts (same total weight)
///      yields the same total rewards — sybil is pointless. `weight = amount * boost`,
///      and boost depends only on lock duration, so splitting cannot inflate it.
contract Staking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant ACC = 1e18; // accumulator precision
    uint256 public constant COOLDOWN = 7 days;

    IERC20 public immutable ticket;
    IStockVault public immutable treasury;

    uint64 public maxLock = 365 days; // lock giving the full 3x
    uint32 public constant MAX_BOOST_BPS = 30_000; // 3x
    uint32 public constant BASE_BOOST_BPS = 10_000; // 1x

    address public distributor; // FeeRouter — may notify dividends

    struct UserInfo {
        uint256 amount; // staked principal (TICKET)
        uint256 weight; // amount * boostBps / BPS (0 while in cooldown)
        uint32 boostBps;
        uint64 lockEnd; // principal locked until
        uint64 cooldownEnd; // 0 unless unstake requested
    }

    uint256 public totalWeight;
    mapping(address => UserInfo) public users;

    // reward accounting
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public accRewardPerWeight; // token => acc (1e18)
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => token => debt
    mapping(address => mapping(address => uint256)) public claimable; // user => token => buffered

    event DistributorSet(address distributor);
    event MaxLockSet(uint64 maxLock);
    event Staked(address indexed user, uint256 amount, uint64 lockEnd, uint32 boostBps, uint256 weight);
    event DividendNotified(address indexed token, uint256 amount, uint256 totalWeight);
    event UnstakeRequested(address indexed user, uint64 cooldownEnd);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyExited(address indexed user, uint256 amount);
    event Claimed(address indexed user, address indexed token, uint256 amount);

    error BadParam();
    error NotDistributor();
    error Locked();
    error InCooldown();
    error NotInCooldown();
    error CooldownNotElapsed();
    error NothingStaked();

    constructor(address owner_, IERC20 ticket_, IStockVault treasury_) Ownable(owner_) {
        if (address(ticket_) == address(0) || address(treasury_) == address(0)) revert BadParam();
        ticket = ticket_;
        treasury = treasury_;
    }

    // ------------------------------------------------------------------- admin
    function setDistributor(address d) external onlyOwner {
        distributor = d;
        emit DistributorSet(d);
    }

    function setMaxLock(uint64 m) external onlyOwner {
        if (m == 0) revert BadParam();
        maxLock = m;
        emit MaxLockSet(m);
    }

    // ------------------------------------------------------------------- views
    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function boostFor(uint64 lockDuration) public view returns (uint32) {
        if (lockDuration >= maxLock) return MAX_BOOST_BPS;
        // linear 1x..3x across [0, maxLock]
        uint256 extra = (uint256(MAX_BOOST_BPS - BASE_BOOST_BPS) * lockDuration) / maxLock;
        return uint32(BASE_BOOST_BPS + extra);
    }

    /// @notice Total currently-claimable (vested + buffered) of `token` for `user`.
    function pending(address user, address token) public view returns (uint256) {
        UserInfo memory u = users[user];
        uint256 acc = accRewardPerWeight[token];
        uint256 accrued = (u.weight * acc) / ACC;
        uint256 debt = rewardDebt[user][token];
        uint256 live = accrued > debt ? accrued - debt : 0;
        return claimable[user][token] + live;
    }

    // -------------------------------------------------------------- dividends
    /// @notice FeeRouter credits a stock dividend; tokens themselves already sit in the
    ///         Treasury. Distributed pro-rata to current weight (time-weighted: only
    ///         stakers present now share it). If nobody is staked, it is skipped (the
    ///         tokens simply remain as treasury reserves — still solvent).
    function notifyDividend(address token, uint256 amount) external {
        if (msg.sender != distributor) revert NotDistributor();
        if (amount == 0) return;
        if (!isRewardToken[token]) {
            isRewardToken[token] = true;
            rewardTokens.push(token);
        }
        uint256 tw = totalWeight;
        if (tw == 0) return; // no stakers → leave in treasury, nothing to credit
        accRewardPerWeight[token] += (amount * ACC) / tw;
        emit DividendNotified(token, amount, tw);
    }

    // ------------------------------------------------------------------- stake
    /// @notice Stake `amount` of $TICKET with a `lockDuration` (longer → up to 3x weight).
    ///         Adding to an existing stake may only extend, never shorten, the lock.
    function stake(uint256 amount, uint64 lockDuration) external nonReentrant {
        if (amount == 0 || lockDuration > maxLock) revert BadParam();
        UserInfo storage u = users[msg.sender];
        if (u.cooldownEnd != 0) revert InCooldown();

        _settle(msg.sender, u.weight);

        uint64 newLockEnd = uint64(block.timestamp) + lockDuration;
        if (newLockEnd < u.lockEnd) revert Locked(); // cannot reduce existing lock

        ticket.safeTransferFrom(msg.sender, address(this), amount);

        u.amount += amount;
        u.lockEnd = newLockEnd;
        u.boostBps = boostFor(lockDuration);

        uint256 oldWeight = u.weight;
        uint256 newWeight = (u.amount * u.boostBps) / BPS;
        u.weight = newWeight;
        totalWeight = totalWeight - oldWeight + newWeight;

        _resetDebt(msg.sender, newWeight);
        emit Staked(msg.sender, amount, u.lockEnd, u.boostBps, newWeight);
    }

    /// @notice Begin the 7-day unstake cooldown. Requires the lock to have expired.
    ///         Weight is removed immediately (stops earning); accrued rewards are banked.
    function requestUnstake() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        if (u.amount == 0) revert NothingStaked();
        if (u.cooldownEnd != 0) revert InCooldown();
        if (block.timestamp < u.lockEnd) revert Locked();

        _settle(msg.sender, u.weight);

        totalWeight -= u.weight;
        u.weight = 0;
        _resetDebt(msg.sender, 0);

        u.cooldownEnd = uint64(block.timestamp) + uint64(COOLDOWN);
        emit UnstakeRequested(msg.sender, u.cooldownEnd);
    }

    /// @notice Withdraw principal after the cooldown. Banked rewards remain claimable.
    function withdraw() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        if (u.cooldownEnd == 0) revert NotInCooldown();
        if (block.timestamp < u.cooldownEnd) revert CooldownNotElapsed();

        uint256 amount = u.amount;
        u.amount = 0;
        u.cooldownEnd = 0;
        u.lockEnd = 0;
        u.boostBps = 0;

        ticket.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim vested stock dividends for a specific token (pulled from Treasury).
    function claim(address token) public nonReentrant returns (uint256 amt) {
        amt = _claim(msg.sender, token);
    }

    /// @notice Claim all reward tokens.
    function claimAll() external nonReentrant {
        address[] memory toks = rewardTokens;
        UserInfo memory u = users[msg.sender];
        // settle live rewards into buffer first
        _settleView(msg.sender, u.weight);
        for (uint256 i; i < toks.length; ++i) {
            _payout(msg.sender, toks[i]);
        }
    }

    /// @notice Non-custodial escape hatch: return principal immediately, bypassing lock
    ///         and cooldown, FORFEITING all unvested + buffered rewards (the ve penalty).
    function emergencyExit() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        uint256 amount = u.amount;
        if (amount == 0) revert NothingStaked();

        // forfeit: drop weight, wipe buffers & debts — do NOT settle
        if (u.weight != 0) {
            totalWeight -= u.weight;
        }
        address[] memory toks = rewardTokens;
        for (uint256 i; i < toks.length; ++i) {
            claimable[msg.sender][toks[i]] = 0;
            rewardDebt[msg.sender][toks[i]] = 0;
        }
        u.amount = 0;
        u.weight = 0;
        u.cooldownEnd = 0;
        u.lockEnd = 0;
        u.boostBps = 0;

        ticket.safeTransfer(msg.sender, amount);
        emit EmergencyExited(msg.sender, amount);
    }

    // --------------------------------------------------------------- internals
    /// @dev Bank live rewards for all tokens into the claimable buffer (storage write).
    function _settle(address user, uint256 weight) internal {
        address[] memory toks = rewardTokens;
        for (uint256 i; i < toks.length; ++i) {
            address t = toks[i];
            uint256 accrued = (weight * accRewardPerWeight[t]) / ACC;
            uint256 debt = rewardDebt[user][t];
            if (accrued > debt) {
                claimable[user][t] += accrued - debt;
            }
        }
    }

    /// @dev Same as _settle but used before per-token payout in claimAll.
    function _settleView(address user, uint256 weight) internal {
        _settle(user, weight);
        _resetDebt(user, weight);
    }

    function _resetDebt(address user, uint256 weight) internal {
        address[] memory toks = rewardTokens;
        for (uint256 i; i < toks.length; ++i) {
            rewardDebt[user][toks[i]] = (weight * accRewardPerWeight[toks[i]]) / ACC;
        }
    }

    function _claim(address user, address token) internal returns (uint256 amt) {
        UserInfo memory u = users[user];
        // bank live rewards for this token
        uint256 accrued = (u.weight * accRewardPerWeight[token]) / ACC;
        uint256 debt = rewardDebt[user][token];
        if (accrued > debt) {
            claimable[user][token] += accrued - debt;
        }
        rewardDebt[user][token] = accrued;
        amt = _payout(user, token);
    }

    function _payout(address user, address token) internal returns (uint256 amt) {
        amt = claimable[user][token];
        if (amt == 0) return 0;
        claimable[user][token] = 0;
        // solvency-gated: Treasury reverts if it does not hold `amt`
        treasury.releaseTo(token, user, amt);
        emit Claimed(user, token, amt);
    }
}
