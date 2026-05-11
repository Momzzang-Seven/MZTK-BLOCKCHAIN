// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IEscrowBase} from "./IEscrowBase.sol";

/// @notice Interface for the MZTK Marketplace Escrow contract.
///         Common admin events, errors, and functions are inherited from IEscrowBase.
interface IMarketplaceEscrow is IEscrowBase {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct ClassOrder {
        bytes32 orderId;
        uint256 price;
        address token;
        uint48 deadline; // Unix timestamp after which the buyer may self-refund
        uint16 state;
        address buyer;
        address trainer;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event ClassPurchased(
        bytes32 indexed orderId, address indexed buyer, address indexed trainer, address token, uint256 price
    );
    event ClassConfirmed(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event ClassCancelled(bytes32 indexed orderId, address indexed buyer, uint256 price);
    event AdminSettled(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event AdminRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);
    /// @dev Emitted when the buyer self-refunds after the deadline has passed.
    event DeadlineRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidPrice();
    error InvalidId();
    error OrderAlreadyExists();
    error OrderNotFound();
    error AlreadySettled();
    error OnlyBuyer();
    error OnlyBuyerOrTrainer();
    error CannotBuyOwnClass();
    error DeadlineNotExpired();
    error DeadlineExpired();

    // ─── Functions ────────────────────────────────────────────────────────────

    /// @notice Purchase a class; locks `price` tokens in escrow.
    ///         Requires a valid server-issued EIP-712 authorization.
    function purchaseClass(
        bytes32 orderId,
        address token,
        address trainer,
        uint256 price,
        uint256 signedAt,
        bytes calldata signature
    ) external;

    /// @notice Buyer confirms class completion; releases payment to the trainer.
    ///         Requires a valid server-issued EIP-712 authorization.
    function confirmClass(bytes32 orderId, uint256 signedAt, bytes calldata signature) external;

    /// @notice Buyer or trainer cancels the order; refunds locked tokens to the buyer.
    ///         Requires a valid server-issued EIP-712 authorization.
    function cancelClass(bytes32 orderId, uint256 signedAt, bytes calldata signature) external;

    /// @notice Owner/relayer settles the order in favour of the trainer.
    function adminSettle(bytes32 orderId) external;

    /// @notice Owner/relayer refunds the order in favour of the buyer.
    function adminRefund(bytes32 orderId) external;

    /// @notice Permissionless refund; callable by anyone once `deadline` has passed.
    function claimExpiredRefund(bytes32 orderId) external;

    function getOrder(bytes32 orderId) external view returns (ClassOrder memory);
    function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory);
}
