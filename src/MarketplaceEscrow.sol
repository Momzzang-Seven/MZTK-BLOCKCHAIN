// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMarketplaceEscrow} from "./interfaces/IMarketplaceEscrow.sol";

contract MarketplaceEscrow is IMarketplaceEscrow, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_CONFIRMED = 2000;
    uint16 public constant STATE_CANCELLED = 3000;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_ADMIN_REFUNDED = 5000;

    mapping(bytes32 => ClassOrder) public orders;
    mapping(address => bool) public isSupportedToken;
    mapping(address => bool) public isRelayer;

    modifier onlyRelayerOrOwner() {
        _onlyRelayerOrOwner();
        _;
    }

    function _onlyRelayerOrOwner() internal view {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
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

    function purchaseClass(bytes32 orderId, address token, address trainer, uint256 price) external {
        if (token == address(0) || trainer == address(0) || orderId == bytes32(0)) revert InvalidAddress();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (price == 0) revert InvalidPrice();
        if (msg.sender == trainer) revert CannotBuyOwnClass();
        if (orders[orderId].buyer != address(0)) revert OrderAlreadyExists();

        orders[orderId] = ClassOrder({
            orderId: orderId, price: price, token: token, state: STATE_CREATED, buyer: msg.sender, trainer: trainer
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, token, price);
    }

    function confirmClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();

        o.state = STATE_CONFIRMED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    function cancelClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();
        if (msg.sender != o.buyer && msg.sender != o.trainer) revert OnlyBuyerOrTrainer();

        o.state = STATE_CANCELLED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    function adminSettle(bytes32 orderId) external onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();

        o.state = STATE_ADMIN_SETTLED;
        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit AdminSettled(orderId, o.trainer, o.price);
    }

    function adminRefund(bytes32 orderId) external onlyRelayerOrOwner {
        ClassOrder storage o = orders[orderId];
        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.state != STATE_CREATED) revert AlreadySettled();

        o.state = STATE_ADMIN_REFUNDED;
        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit AdminRefunded(orderId, o.buyer, o.price);
    }

    function getOrder(bytes32 orderId) external view returns (ClassOrder memory) {
        return orders[orderId];
    }

    function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory) {
        ClassOrder[] memory result = new ClassOrder[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            result[i] = orders[orderIds[i]];
        }
        return result;
    }
}
