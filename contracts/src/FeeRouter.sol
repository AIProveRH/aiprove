// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBuybackExecutor} from "./interfaces/IBuybackExecutor.sol";
import {IStaking} from "./interfaces/IStaking.sol";

/// @title FeeRouter
/// @notice Receives the pons creator fee + GMV rake (any accepted token) and executes
///         the treasury split: 40% buyback-burn $TICKET / 35% staker-dividends /
///         25% platform-bounty-fund. Split params are owner/timelock-settable.
///
/// @dev Money placement after a split of `token`:
///      - buyback: if token is $TICKET it is burned directly; otherwise the stock is
///        handed to the IBuybackExecutor which swaps→$TICKET and burns.
///      - dividends: tokens are moved to the Treasury and the Staking module is credited
///        (stakers pull-claim from the Treasury — solvency-gated there).
///      - platform: tokens are moved to the Treasury, earmarked for platform-seeded
///        bounties (spent by governance from the Treasury).
///      Remainder/dust is folded into the platform slice so nothing is stranded.
contract FeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    ERC20Burnable public immutable ticket;
    address public treasury; // StockVault
    IStaking public staking;
    IBuybackExecutor public buybackExecutor;

    uint32 public buybackBps = 4000; // 40%
    uint32 public dividendsBps = 3500; // 35%
    uint32 public platformBps = 2500; // 25%

    event Distributed(
        address indexed token, uint256 total, uint256 buyback, uint256 dividends, uint256 platform
    );
    event SplitSet(uint32 buybackBps, uint32 dividendsBps, uint32 platformBps);
    event WiringSet(address treasury, address staking, address buybackExecutor);

    error BadParam();
    error SplitNot100();
    error NotConfigured();

    constructor(address owner_, ERC20Burnable ticket_, address treasury_) Ownable(owner_) {
        if (address(ticket_) == address(0) || treasury_ == address(0)) revert BadParam();
        ticket = ticket_;
        treasury = treasury_;
    }

    // ------------------------------------------------------------------- admin
    function setWiring(address treasury_, IStaking staking_, IBuybackExecutor buybackExecutor_)
        external
        onlyOwner
    {
        if (treasury_ == address(0)) revert BadParam();
        treasury = treasury_;
        staking = staking_;
        buybackExecutor = buybackExecutor_;
        emit WiringSet(treasury_, address(staking_), address(buybackExecutor_));
    }

    function setSplit(uint32 buybackBps_, uint32 dividendsBps_, uint32 platformBps_) external onlyOwner {
        if (uint256(buybackBps_) + dividendsBps_ + platformBps_ != BPS) revert SplitNot100();
        buybackBps = buybackBps_;
        dividendsBps = dividendsBps_;
        platformBps = platformBps_;
        emit SplitSet(buybackBps_, dividendsBps_, platformBps_);
    }

    // ------------------------------------------------------------------- route
    /// @notice Split the router's current balance of `token` per the configured ratios.
    ///         Permissionless keeper call — anyone can trigger routing of accrued fees.
    function distribute(address token) external nonReentrant {
        uint256 total = IERC20(token).balanceOf(address(this));
        if (total == 0) return;

        uint256 buyback = total * buybackBps / BPS;
        uint256 dividends = total * dividendsBps / BPS;
        uint256 platform = total - buyback - dividends; // remainder → platform (no dust loss)

        // ---- buyback-burn leg
        if (buyback != 0) {
            if (token == address(ticket)) {
                ticket.burn(buyback);
            } else {
                if (address(buybackExecutor) == address(0)) revert NotConfigured();
                IERC20(token).safeTransfer(address(buybackExecutor), buyback);
                buybackExecutor.buybackAndBurn(token, buyback);
            }
        }

        // ---- dividends leg (tokens parked in treasury; stakers pull-claim)
        if (dividends != 0) {
            if (address(staking) == address(0)) revert NotConfigured();
            IERC20(token).safeTransfer(treasury, dividends);
            staking.notifyDividend(token, dividends);
        }

        // ---- platform-bounty-fund leg (held in treasury)
        if (platform != 0) {
            IERC20(token).safeTransfer(treasury, platform);
        }

        emit Distributed(token, total, buyback, dividends, platform);
    }
}
