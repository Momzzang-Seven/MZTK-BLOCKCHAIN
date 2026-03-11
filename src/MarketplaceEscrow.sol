// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MarketplaceEscrow (V2 - Hybrid & Resilient)
 * @notice 마켓플레이스 에스크로 컨트랙트
 *         시간(Time)에 대한 스케줄링 로직을 모두 오프체인(백엔드)으로 이관하고,
 *         스마트 컨트랙트는 구매자, 판매자, 관리자(Relayer) 3자 간의 권한에 따른
 *         "자금 보관 및 송금" 역할(Dumb Contract)만 수행합니다.
 */
contract MarketplaceEscrow is Ownable {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Types ────────────────────────────

    struct ClassOrder {
        address buyer;
        address trainer;
        address token;
        uint256 price;
        bool isSettled;
    }

    // ──────────────────────────── State ────────────────────────────

    uint256 public orderCount;

    /// @dev orderId => ClassOrder
    mapping(uint256 => ClassOrder) public orders;

    // ──────────────────────────── Events ───────────────────────────

    event ClassPurchased(
        uint256 indexed orderId,
        address indexed buyer,
        address indexed trainer,
        address token,
        uint256 price
    );

    event ClassConfirmed(uint256 indexed orderId, address indexed trainer, uint256 price);
    event ClassCancelled(uint256 indexed orderId, address indexed buyer, uint256 price);
    event AdminSettled(uint256 indexed orderId, address indexed trainer, uint256 price);
    event AdminRefunded(uint256 indexed orderId, address indexed buyer, uint256 price);

    // ──────────────────────────── Errors ───────────────────────────

    error InvalidAddress();
    error InvalidPrice();
    error OrderNotFound();
    error AlreadySettled();
    error OnlyBuyer();
    error OnlyTrainer();
    error CannotBuyOwnClass();

    // ────────────────────────── Constructor ────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ──────────────────────── External Functions ───────────────────

    /**
     * @notice 구매자(Buyer): 클래스 대금 예치
     */
    function purchaseClass(
        address token,
        address trainer,
        uint256 price
    ) external returns (uint256 orderId) {
        if (token == address(0) || trainer == address(0)) revert InvalidAddress();
        if (price == 0) revert InvalidPrice();
        if (msg.sender == trainer) revert CannotBuyOwnClass();

        orderId = orderCount++;

        orders[orderId] = ClassOrder({
            buyer: msg.sender,
            trainer: trainer,
            token: token,
            price: price,
            isSettled: false
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, token, price);
    }

    /**
     * @notice 구매자(Buyer): 클래스 확정 및 트레이너에게 정산
     */
    function confirmClass(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    /**
     * @notice 판매자(Trainer): 예약 취소 및 구매자에게 환불
     */
    function cancelClass(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();
        if (msg.sender != o.trainer) revert OnlyTrainer();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    /**
     * @notice 플래폼 관리자(Admin): 조건/분쟁 시 트레이너에게 강제 정산 (Outbox Relay)
     */
    function adminSettle(uint256 orderId) external onlyOwner {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.trainer, o.price);

        emit AdminSettled(orderId, o.trainer, o.price);
    }

    /**
     * @notice 플랫폼 관리자(Admin): 타임아웃/분쟁/정원 초과 시 구매자에게 강제 환불 (Outbox Relay)
     */
    function adminRefund(uint256 orderId) external onlyOwner {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit AdminRefunded(orderId, o.buyer, o.price);
    }

    // ──────────────────────── View Functions ──────────────────────

    function getOrder(uint256 orderId)
        external
        view
        returns (
            address buyer,
            address trainer,
            address token,
            uint256 price,
            bool isSettled
        )
    {
        ClassOrder storage o = orders[orderId];
        return (o.buyer, o.trainer, o.token, o.price, o.isSettled);
    }
}
