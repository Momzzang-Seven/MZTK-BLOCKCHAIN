// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IMarketplaceEscrow {
    struct ClassOrder {
        bytes32 orderId;
        uint256 price;
        address token;
        uint48 deadline; // Unix timestamp after which the buyer may self-refund
        uint16 state;
        address buyer;
        address trainer;
    }

    event ClassPurchased(
        bytes32 indexed orderId, address indexed buyer, address indexed trainer, address token, uint256 price
    );
    event ClassConfirmed(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event ClassCancelled(bytes32 indexed orderId, address indexed buyer, uint256 price);
    event AdminSettled(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event AdminRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);
    // Emitted when the buyer self-refunds after the deadline has passed
    event DeadlineRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);
    event TokenSupportUpdated(address indexed token, bool isSupported);
    event RelayerUpdated(address indexed relayer, bool isAuthorized);
    event DefaultDeadlineDurationUpdated(uint48 newDuration);
    // Emitted when the server signature validity window is updated
    event SigValidityDurationUpdated(uint48 newDuration);
    // Emitted when the trusted server signer address is updated
    event SignerUpdated(address indexed newSigner);

    error InvalidAddress();
    error InvalidPrice();
    error InvalidDeadline();
    error UnsupportedToken();
    error OrderAlreadyExists();
    error OrderNotFound();
    error InvalidId(); // non-address zero identifier (e.g. orderId)
    error AlreadySettled();
    error OnlyBuyer();
    error OnlyBuyerOrTrainer();
    error OnlyRelayerOrOwner();
    error CannotBuyOwnClass();
    error DeadlineNotExpired();
    error DeadlineExpired();
    error InvalidSignature();
    error SignatureExpired();

    function updateTokenSupport(address token, bool isSupported) external;
    function updateRelayer(address relayer, bool isAuthorized) external;
    function updateDefaultDeadlineDuration(uint48 newDuration) external;
    function updateSigValidityDuration(uint48 newDuration) external;
    function setSigner(address newSigner) external;
    // Requires a valid EIP-712 signature from the server; signedAt is when the server signed
    function purchaseClass(
        bytes32 orderId,
        address token,
        address trainer,
        uint256 price,
        uint256 signedAt,
        bytes calldata signature
    ) external;
    // Buyer confirms class was received; transfers locked tokens to trainer
    function confirmClass(bytes32 orderId) external;
    // Buyer or trainer cancels order; refunds locked tokens to buyer
    function cancelClass(bytes32 orderId) external;
    function adminSettle(bytes32 orderId) external;
    function adminRefund(bytes32 orderId) external;
    // Permissionless refund callable by anyone once the order deadline has passed
    function claimExpiredRefund(bytes32 orderId) external;
    function getOrder(bytes32 orderId) external view returns (ClassOrder memory);
    function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory);
    function nonces(address buyer) external view returns (uint256);
}
