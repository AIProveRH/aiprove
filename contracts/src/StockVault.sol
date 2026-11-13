// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StockVault (Treasury)
/// @notice Holds tokenized-stock ERC-20s (and $TICKET). Public proof-of-reserves.
///         Funds buyback-burn / staker-dividends / platform-bounties.
///
/// @dev    THE CRITICAL INVARIANT lives here: `releaseTo` can never move more of a
///         token than the vault actually holds. Every outflow path in the whole system
///         that is backed by treasury reserves goes through this one function, so
///         "the board only ever pays what the treasury holds" is enforced in exactly
///         one place and is trivially auditable. CEI + nonReentrant on the outflow.
contract StockVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Addresses allowed to pull reserves (FeeRouter, Staking, BountyBoard, PayoutModule).
    mapping(address => bool) public isSpender;

    event SpenderSet(address indexed spender, bool allowed);
    event Released(address indexed token, address indexed to, uint256 amount, address indexed caller);
    event Deposited(address indexed token, address indexed from, uint256 amount);

    error NotSpender();
    error Insolvent(address token, uint256 requested, uint256 held);
    error ZeroAddress();

    modifier onlySpender() {
        if (!isSpender[msg.sender]) revert NotSpender();
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Owner authorizes/revokes a spender that may call `releaseTo`.
    function setSpender(address spender, bool allowed) external onlyOwner {
        if (spender == address(0)) revert ZeroAddress();
        isSpender[spender] = allowed;
        emit SpenderSet(spender, allowed);
    }

    /// @notice Live proof-of-reserves — the vault's real on-chain balance.
    function reserves(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Optional explicit deposit (pulls `amount` from caller). Not required —
    ///         a plain transfer in also works since reserves are read live — but handy
    ///         for off-chain accounting / event indexing.
    function deposit(address token, uint256 amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    /// @notice Release `amount` of `token` to `to`. SOLVENCY-GATED: reverts if the
    ///         vault does not currently hold at least `amount`. This is the single
    ///         chokepoint that makes over-payment impossible.
    function releaseTo(address token, address to, uint256 amount)
        external
        onlySpender
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 held = IERC20(token).balanceOf(address(this));
        if (amount > held) revert Insolvent(token, amount, held);
        // CEI: the balance check is the state read; the external transfer is last,
        // and nonReentrant blocks re-entry draining the just-checked balance.
        IERC20(token).safeTransfer(to, amount);
        emit Released(token, to, amount, msg.sender);
    }
}
