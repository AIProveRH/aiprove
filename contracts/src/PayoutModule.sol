// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title PayoutModule
/// @notice Converts between $TICKET and tokenized-stock amounts for stock-denominated
///         payouts, via a Chainlink-style oracle with staleness / zero / deviation
///         guards and a stock allowlist. The real Chainlink aggregators slot in later;
///         a mock feed drives the tests.
///
/// @dev All USD math is normalized to 1e18 ("USD-wad") internally regardless of feed
///      decimals or token decimals, so new stocks with odd decimals plug in safely.
///      $TICKET is assumed 18 decimals. `ticketUsdPrice1e18` is a governance input
///      (fed by a pons TWAP in production) — documented as a resolved ambiguity.
contract PayoutModule is Ownable2Step {
    struct Feed {
        IAggregatorV3 aggregator; // price source (USD per 1 whole stock)
        uint64 maxStaleness; // max seconds since updatedAt
        uint32 maxDeviationBps; // max |price - anchor| / anchor; 0 disables
        uint32 multiplierBps; // haircut/premium applied to conversions (10000 = 1x)
        uint256 anchorPrice1e18; // deviation reference (owner-maintained)
        uint8 stockDecimals; // cached ERC20 decimals of the stock token
        bool enabled; // allowlist flag
    }

    /// @notice USD price of 1 $TICKET, 1e18-scaled (governance / pons-TWAP input).
    uint256 public ticketUsdPrice1e18;

    mapping(address => Feed) public feeds;

    event FeedSet(
        address indexed stock,
        address aggregator,
        uint64 maxStaleness,
        uint32 maxDeviationBps,
        uint32 multiplierBps
    );
    event FeedDisabled(address indexed stock);
    event AnchorSet(address indexed stock, uint256 anchorPrice1e18);
    event TicketUsdPriceSet(uint256 price1e18);

    error NotAllowed(address stock);
    error ZeroPrice();
    error StalePrice(uint256 updatedAt, uint256 nowTs);
    error IncompleteRound();
    error PriceDeviation(uint256 price1e18, uint256 anchor1e18);
    error BadConfig();

    constructor(address owner_, uint256 ticketUsdPrice1e18_) Ownable(owner_) {
        if (ticketUsdPrice1e18_ == 0) revert BadConfig();
        ticketUsdPrice1e18 = ticketUsdPrice1e18_;
    }

    // ----------------------------------------------------------------- admin

    function setTicketUsdPrice(uint256 newPrice1e18) external onlyOwner {
        if (newPrice1e18 == 0) revert BadConfig();
        ticketUsdPrice1e18 = newPrice1e18;
        emit TicketUsdPriceSet(newPrice1e18);
    }

    function setFeed(
        address stock,
        IAggregatorV3 aggregator,
        uint64 maxStaleness,
        uint32 maxDeviationBps,
        uint32 multiplierBps
    ) external onlyOwner {
        if (stock == address(0) || address(aggregator) == address(0)) revert BadConfig();
        if (maxStaleness == 0 || multiplierBps == 0) revert BadConfig();
        feeds[stock] = Feed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            maxDeviationBps: maxDeviationBps,
            multiplierBps: multiplierBps,
            anchorPrice1e18: feeds[stock].anchorPrice1e18,
            stockDecimals: IERC20Metadata(stock).decimals(),
            enabled: true
        });
        emit FeedSet(stock, address(aggregator), maxStaleness, maxDeviationBps, multiplierBps);
    }

    function disableFeed(address stock) external onlyOwner {
        feeds[stock].enabled = false;
        emit FeedDisabled(stock);
    }

    /// @notice Owner sets/refreshes the deviation anchor (a trusted recent price).
    function setAnchor(address stock, uint256 anchorPrice1e18) external onlyOwner {
        if (!feeds[stock].enabled) revert NotAllowed(stock);
        feeds[stock].anchorPrice1e18 = anchorPrice1e18;
        emit AnchorSet(stock, anchorPrice1e18);
    }

    function isAllowed(address stock) external view returns (bool) {
        return feeds[stock].enabled;
    }

    // ------------------------------------------------------------- oracle read

    /// @notice Guarded, normalized price of `stock` in USD-wad (1e18). Reverts on
    ///         not-allowlisted / zero / stale / incomplete-round / deviation.
    function price1e18(address stock) public view returns (uint256) {
        Feed memory f = feeds[stock];
        if (!f.enabled) revert NotAllowed(stock);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            f.aggregator.latestRoundData();

        if (answer <= 0) revert ZeroPrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > f.maxStaleness) {
            revert StalePrice(updatedAt, block.timestamp);
        }
        if (answeredInRound < roundId) revert IncompleteRound();

        uint8 feedDec = f.aggregator.decimals();
        uint256 p = _scaleTo1e18(uint256(answer), feedDec);

        if (f.maxDeviationBps != 0 && f.anchorPrice1e18 != 0) {
            uint256 diff = p > f.anchorPrice1e18 ? p - f.anchorPrice1e18 : f.anchorPrice1e18 - p;
            if (diff * 10_000 > f.anchorPrice1e18 * f.maxDeviationBps) {
                revert PriceDeviation(p, f.anchorPrice1e18);
            }
        }
        return p;
    }

    // ------------------------------------------------------------- conversions

    /// @notice How much `stock` (its own decimals) a given $TICKET amount buys.
    function quoteTicketToStock(address stock, uint256 ticketAmount)
        external
        view
        returns (uint256 stockAmount)
    {
        Feed memory f = feeds[stock];
        uint256 p = price1e18(stock);
        // usd-wad = ticket(1e18) * ticketUsdPrice(1e18) / 1e18
        uint256 usd = Math.mulDiv(ticketAmount, ticketUsdPrice1e18, 1e18);
        // stock = usd-wad * 10^stockDec / price-wad
        stockAmount = Math.mulDiv(usd, 10 ** f.stockDecimals, p);
        stockAmount = Math.mulDiv(stockAmount, f.multiplierBps, 10_000);
    }

    /// @notice USD-equivalent value (TICKET-denominated, 1e18) of a stock amount.
    ///         Used by burn-to-post to price a stock reward in $TICKET.
    function quoteStockToTicket(address stock, uint256 stockAmount)
        external
        view
        returns (uint256 ticketAmount)
    {
        Feed memory f = feeds[stock];
        uint256 p = price1e18(stock);
        // usd-wad = stock * price-wad / 10^stockDec
        uint256 usd = Math.mulDiv(stockAmount, p, 10 ** f.stockDecimals);
        // ticket(1e18) = usd-wad * 1e18 / ticketUsdPrice(1e18)
        ticketAmount = Math.mulDiv(usd, 1e18, ticketUsdPrice1e18);
        ticketAmount = Math.mulDiv(ticketAmount, f.multiplierBps, 10_000);
    }

    // --------------------------------------------------------------- internals

    function _scaleTo1e18(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return v;
        if (dec < 18) return v * (10 ** (18 - dec));
        return v / (10 ** (dec - 18));
    }
}
