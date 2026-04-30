// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IMarketplaceEscrow} from "./interfaces/IMarketplaceEscrow.sol";

contract MarketplaceEscrow is IMarketplaceEscrow, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    // EIP-712 typehash for server-signed purchase authorization
    bytes32 private constant _PURCHASE_CLASS_TYPEHASH = keccak256(
        "PurchaseClass(address buyer,bytes32 orderId,address token,address trainer,uint256 price,uint256 nonce,uint256 signedAt)"
    );

    // State constants representing the lifecycle of an order
    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_CONFIRMED = 2000;
    uint16 public constant STATE_CANCELLED = 3000;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_ADMIN_REFUNDED = 5000;
    uint16 public constant STATE_DEADLINE_REFUNDED = 6000;

    // Minimum allowed deadline duration (1 day) to prevent abuse
    uint48 public constant MIN_DEADLINE_DURATION = 1 days;
    // Maximum allowed escrow deadline duration (1 year)
    uint48 public constant MAX_DEADLINE_DURATION = 365 days;
    // Minimum allowed server signature validity window (1 minute)
    uint48 public constant MIN_SIG_VALIDITY_DURATION = 1 minutes;
    // Maximum allowed server signature validity window (1 hour)
    uint48 public constant MAX_SIG_VALIDITY_DURATION = 1 hours;

    // Default duration from purchase to escrow deadline: 30 days
    uint48 public defaultDeadlineDuration = 30 days;

    // Window after signedAt within which a server signature remains valid (default: 15 minutes)
    // The contract enforces this; the server only needs to include signedAt in the signature
    uint48 public sigValidityDuration = 15 minutes;

    // Server address whose EIP-712 signature is required for purchaseClass
    address public signer;

    // Per-buyer nonce to prevent server signature replay
    mapping(address => uint256) public nonces;

    // Mapping from order ID to ClassOrder details
    mapping(bytes32 => ClassOrder) public orders;
    // Mapping to track supported ERC20 tokens for payment
    mapping(address => bool) public isSupportedToken;
    // Mapping to track authorized relayer addresses
    mapping(address => bool) public isRelayer;

    // Modifier to restrict access to only relayer or owner
    modifier onlyRelayerOrOwner() {
        _onlyRelayerOrOwner();
        _;
    }

    function _onlyRelayerOrOwner() internal view {
        if (!isRelayer[msg.sender] && msg.sender != owner()) {
            revert OnlyRelayerOrOwner();
        }
    }

    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) EIP712("MarketplaceEscrow", "1") {
        if (initialSigner == address(0)) revert InvalidAddress();
        signer = initialSigner;
        emit SignerUpdated(initialSigner);
    }

    // Updates the trusted server signer address
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidAddress();
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    // Updates the support status of an ERC20 token
    function updateTokenSupport(address token, bool isSupported) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    // Updates the authorization status of a relayer
    function updateRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    // Updates the default escrow deadline duration applied to new orders
    function updateDefaultDeadlineDuration(uint48 newDuration) external onlyOwner {
        if (newDuration < MIN_DEADLINE_DURATION || newDuration > MAX_DEADLINE_DURATION) revert InvalidDeadline();
        defaultDeadlineDuration = newDuration;
        emit DefaultDeadlineDurationUpdated(newDuration);
    }

    // Updates the validity window for server-issued signatures
    function updateSigValidityDuration(uint48 newDuration) external onlyOwner {
        if (newDuration < MIN_SIG_VALIDITY_DURATION || newDuration > MAX_SIG_VALIDITY_DURATION) {
            revert InvalidDeadline();
        }
        sigValidityDuration = newDuration;
        emit SigValidityDurationUpdated(newDuration);
    }

    // Purchases a class by locking the required token amount in the escrow.
    // Requires a valid EIP-712 signature from the server authorizing this specific purchase.
    // signedAt is the unix timestamp when the server signed; the contract checks validity
    // using sigValidityDuration (default 10 min). The server does NOT set the deadline.
    function purchaseClass(
        bytes32 orderId,
        address token,
        address trainer,
        uint256 price,
        uint256 signedAt,
        bytes calldata signature
    ) external {
        if (token == address(0) || trainer == address(0)) revert InvalidAddress();
        if (orderId == bytes32(0)) revert InvalidId();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (price == 0) revert InvalidPrice();
        if (msg.sender == trainer) revert CannotBuyOwnClass();
        if (orders[orderId].buyer != address(0)) revert OrderAlreadyExists();

        // Verify the server-issued EIP-712 authorization
        // signedAt must be in the past, and within the allowed validity window
        if (signedAt > block.timestamp) revert InvalidSignature();
        if (block.timestamp > signedAt + sigValidityDuration) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                _PURCHASE_CLASS_TYPEHASH, msg.sender, orderId, token, trainer, price, nonces[msg.sender], signedAt
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();
        nonces[msg.sender]++;

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

    // Confirms class completion; only the buyer can confirm, which releases payment to the trainer
    function confirmClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();
        // Prevent confirmation after escrow deadline (claimExpiredRefund takes precedence)
        if (block.timestamp > o.deadline) revert DeadlineExpired();

        o.state = STATE_CONFIRMED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    // Cancels the order and refunds locked tokens to the buyer; callable by buyer or trainer.
    // Intentionally has no deadline guard — refunding is always safe regardless of deadline.
    // After deadline, both cancelClass and claimExpiredRefund are callable; first caller wins.
    function cancelClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer && msg.sender != o.trainer) revert OnlyBuyerOrTrainer();

        o.state = STATE_CANCELLED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    // Administratively settles an order, transferring tokens to the trainer
    function adminSettle(bytes32 orderId) external onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        // Prevent settlement after escrow deadline so claimExpiredRefund remains valid
        if (block.timestamp > o.deadline) revert DeadlineExpired();

        o.state = STATE_ADMIN_SETTLED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit AdminSettled(orderId, o.trainer, o.price);
    }

    // Administratively refunds an order, transferring tokens back to the buyer.
    // Intentionally has no deadline guard — refunding is always safe regardless of deadline.
    // After deadline, both adminRefund and claimExpiredRefund are callable; first caller wins.
    function adminRefund(bytes32 orderId) external onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();

        o.state = STATE_ADMIN_REFUNDED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit AdminRefunded(orderId, o.buyer, o.price);
    }

    // Permissionless refund: callable by anyone once the order deadline has passed.
    // Returns locked tokens to the buyer without requiring relayer/owner intervention.
    function claimExpiredRefund(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (block.timestamp <= o.deadline) revert DeadlineNotExpired();

        o.state = STATE_DEADLINE_REFUNDED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit DeadlineRefunded(orderId, o.buyer, o.price);
    }

    // Retrieves the details of a specific order
    function getOrder(bytes32 orderId) external view returns (ClassOrder memory) {
        return orders[orderId];
    }

    // Retrieves the details of multiple orders
    function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory) {
        ClassOrder[] memory result = new ClassOrder[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            result[i] = orders[orderIds[i]];
        }
        return result;
    }
}
