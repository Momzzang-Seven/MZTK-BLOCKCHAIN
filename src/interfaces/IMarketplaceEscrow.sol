// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IMarketplaceEscrow {
    struct ClassOrder {
        bytes32 orderId;
        uint256 price;
        address token;
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
    event TokenSupportUpdated(address indexed token, bool isSupported);
    event RelayerUpdated(address indexed relayer, bool isAuthorized);

    error InvalidAddress();
    error InvalidPrice();
    error UnsupportedToken();
    error OrderAlreadyExists();
    error OrderNotFound();
    error AlreadySettled();
    error OnlyBuyer();
    error OnlyTrainer();
    error OnlyRelayerOrOwner();
    error CannotBuyOwnClass();

    function updateTokenSupport(address token, bool isSupported) external;
    function updateRelayer(address relayer, bool isAuthorized) external;
    function purchaseClass(bytes32 orderId, address token, address trainer, uint256 price) external;
    function confirmClass(bytes32 orderId) external;
    function cancelClass(bytes32 orderId) external;
    function adminSettle(bytes32 orderId) external;
    function adminRefund(bytes32 orderId) external;
    function getOrder(bytes32 orderId) external view returns (ClassOrder memory);
    function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory);
}
