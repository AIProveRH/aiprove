// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPayoutModule
/// @notice Oracle-backed conversion + stock allowlist used by the board to price a
///         stock reward in $TICKET (for burn-to-post / bond sizing).
interface IPayoutModule {
    function isAllowed(address stock) external view returns (bool);
    function quoteStockToTicket(address stock, uint256 stockAmount) external view returns (uint256);
    function quoteTicketToStock(address stock, uint256 ticketAmount) external view returns (uint256);
}
