// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MztkEscrowBase} from "./MztkEscrowBase.sol";
import {IMarketplaceEscrow} from "./interfaces/IMarketplaceEscrow.sol";

contract MarketplaceEscrow is IMarketplaceEscrow, MztkEscrowBase {
    using SafeERC20 for IERC20;

    // ─── EIP-712 typehashes ────────────────────────────────────────────────────

    bytes32 private constant _PURCHASE_CLASS_TYPEHASH = keccak256(
        "PurchaseClass(address buyer,bytes32 orderId,address token,address trainer,uint256 price,uint256 signedAt)"
    );
    bytes32 private constant _CONFIRM_CLASS_TYPEHASH =
        keccak256("ConfirmClass(address buyer,bytes32 orderId,uint256 signedAt)");
    bytes32 private constant _CANCEL_CLASS_TYPEHASH =
        keccak256("CancelClass(address caller,bytes32 orderId,uint256 signedAt)");

    // ─── State constants ───────────────────────────────────────────────────────

    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_CONFIRMED = 2000;
    uint16 public constant STATE_CANCELLED = 3000;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_ADMIN_REFUNDED = 5000;
    uint16 public constant STATE_DEADLINE_REFUNDED = 6000;

    // ─── Storage ───────────────────────────────────────────────────────────────

    /// @notice All class orders, keyed by orderId.
    mapping(bytes32 => ClassOrder) public orders;

    // ─── Constructor ───────────────────────────────────────────────────────────

    constructor(address initialOwner, address initialSigner)
        MztkEscrowBase(initialOwner, initialSigner, "MarketplaceEscrow", "1")
    {}

    // ─── User actions ──────────────────────────────────────────────────────────

    /// @inheritdoc IMarketplaceEscrow
    function purchaseClass(
        bytes32 orderId,
        address token,
        address trainer,
        uint256 price,
        uint256 signedAt,
        bytes calldata signature
    ) external override {
        if (token == address(0) || trainer == address(0)) revert InvalidAddress();
        if (orderId == bytes32(0)) revert InvalidId();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (price == 0) revert InvalidPrice();
        if (msg.sender == trainer) revert CannotBuyOwnClass();
        if (orders[orderId].buyer != address(0)) revert OrderAlreadyExists();

        bytes32 structHash =
            keccak256(abi.encode(_PURCHASE_CLASS_TYPEHASH, msg.sender, orderId, token, trainer, price, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        uint48 deadline = uint48(block.timestamp) + defaultDeadlineDuration;

        orders[orderId] = ClassOrder({
            orderId: orderId,
            price: price,
            token: token,
            deadline: deadline,
            state: STATE_CREATED,
            buyer: msg.sender,
            trainer: trainer
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, token, price);
    }

    /// @inheritdoc IMarketplaceEscrow
    function confirmClass(bytes32 orderId, uint256 signedAt, bytes calldata signature) external override {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();
        if (block.timestamp > o.deadline) revert DeadlineExpired();

        bytes32 structHash = keccak256(abi.encode(_CONFIRM_CLASS_TYPEHASH, msg.sender, orderId, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        o.state = STATE_CONFIRMED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    /// @inheritdoc IMarketplaceEscrow
    function cancelClass(bytes32 orderId, uint256 signedAt, bytes calldata signature) external override {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer && msg.sender != o.trainer) revert OnlyBuyerOrTrainer();

        bytes32 structHash = keccak256(abi.encode(_CANCEL_CLASS_TYPEHASH, msg.sender, orderId, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        o.state = STATE_CANCELLED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    // ─── Relayer / admin actions ───────────────────────────────────────────────

    /// @inheritdoc IMarketplaceEscrow
    function adminSettle(bytes32 orderId) external override onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (block.timestamp > o.deadline) revert DeadlineExpired();

        o.state = STATE_ADMIN_SETTLED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit AdminSettled(orderId, o.trainer, o.price);
    }

    /// @inheritdoc IMarketplaceEscrow
    function adminRefund(bytes32 orderId) external override onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();

        o.state = STATE_ADMIN_REFUNDED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit AdminRefunded(orderId, o.buyer, o.price);
    }

    // ─── Permissionless ───────────────────────────────────────────────────────

    /// @inheritdoc IMarketplaceEscrow
    function claimExpiredRefund(bytes32 orderId) external override {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (block.timestamp <= o.deadline) revert DeadlineNotExpired();

        o.state = STATE_DEADLINE_REFUNDED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit DeadlineRefunded(orderId, o.buyer, o.price);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMarketplaceEscrow
    function getOrder(bytes32 orderId) external view override returns (ClassOrder memory) {
        return orders[orderId];
    }

    /// @inheritdoc IMarketplaceEscrow
    function getOrders(bytes32[] calldata orderIds) external view override returns (ClassOrder[] memory) {
        ClassOrder[] memory result = new ClassOrder[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            result[i] = orders[orderIds[i]];
        }
        return result;
    }
}
