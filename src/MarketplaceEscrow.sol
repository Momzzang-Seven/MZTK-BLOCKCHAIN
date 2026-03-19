// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MarketplaceEscrow is Ownable {
    using SafeERC20 for IERC20;

    struct ClassOrder {
        uint256 price;
        address token;
        bool isSettled;
        address buyer;
        address trainer;
    }

    mapping(bytes32 => ClassOrder) public orders;
    
    mapping(address => bool) public isSupportedToken;
    
    mapping(address => bool) public isRelayer;

    event ClassPurchased(bytes32 indexed orderId, address indexed buyer, address indexed trainer, address token, uint256 price);
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


    modifier onlyRelayerOrOwner() {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function updateTokenSupport(address token, bool isSupported) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    function updateRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    function purchaseClass(
        bytes32 orderId,
        address token,
        address trainer,
        uint256 price
    ) external {
        if (token == address(0) || trainer == address(0) || orderId == bytes32(0)) revert InvalidAddress();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (price == 0) revert InvalidPrice();
        if (msg.sender == trainer) revert CannotBuyOwnClass();
        if (orders[orderId].buyer != address(0)) revert OrderAlreadyExists();

        orders[orderId] = ClassOrder({
            price: price,
            token: token,
            isSettled: false,
            buyer: msg.sender,
            trainer: trainer
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, token, price);
    }

    function confirmClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    function cancelClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();
        if (msg.sender != o.trainer) revert OnlyTrainer();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    function adminSettle(bytes32 orderId) external onlyRelayerOrOwner {
        _adminSettle(orderId);
    }

    function batchAdminSettle(bytes32[] calldata orderIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _adminSettle(orderIds[i]);
        }
    }

    function adminRefund(bytes32 orderId) external onlyRelayerOrOwner {
        _adminRefund(orderId);
    }

    function batchAdminRefund(bytes32[] calldata orderIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _adminRefund(orderIds[i]);
        }
    }

    function _adminSettle(bytes32 orderId) internal {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();

        o.isSettled = true;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit AdminSettled(orderId, o.trainer, o.price);
    }

    function _adminRefund(bytes32 orderId) internal {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();

        o.isSettled = true;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit AdminRefunded(orderId, o.buyer, o.price);
    }

    function getOrder(bytes32 orderId) external view returns (ClassOrder memory) {
        return orders[orderId];
    }
}
