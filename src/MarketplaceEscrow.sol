// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MarketplaceEscrow
 * @notice 마켓플레이스 에스크로 컨트랙트
 *         구매자가 ERC-20 토큰을 예치하고, 클래스 완료 시 트레이너에게 지급
 *         - 구매자 확정(confirmClass): 즉시 트레이너에게 지급
 *         - 자동 정산(releasePayment): 클래스 종료 후 3일 경과 시 누구나 호출 가능
 *         - 구매자 환불(refundClass): 클래스 시작 전 구매자가 환불
 *         - 트레이너 취소(cancelClass): 클래스 시작 전 트레이너가 취소 → 구매자에게 환불
 */
contract MarketplaceEscrow {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Types ────────────────────────────

    struct ClassOrder {
        address buyer;
        address trainer;
        bytes32 classHash;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        bool settled;
    }

    // ──────────────────────────── State ────────────────────────────

    IERC20 public immutable REWARD_TOKEN;
    uint256 public constant AUTO_RELEASE_DELAY = 3 days;

    uint256 public orderCount;

    /// @dev orderId => ClassOrder
    mapping(uint256 => ClassOrder) public orders;

    // ──────────────────────────── Events ───────────────────────────

    event ClassPurchased(
        uint256 indexed orderId,
        address indexed buyer,
        address indexed trainer,
        bytes32 classHash,
        uint256 price,
        uint256 startTime,
        uint256 endTime
    );

    event ClassConfirmed(uint256 indexed orderId, address indexed trainer, uint256 price);

    event PaymentReleased(uint256 indexed orderId, address indexed trainer, uint256 price);

    event ClassRefunded(uint256 indexed orderId, address indexed buyer, uint256 price);

    event ClassCancelled(uint256 indexed orderId, address indexed buyer, uint256 price);

    // ──────────────────────────── Errors ───────────────────────────

    error InvalidClassHash();
    error InvalidPrice();
    error InvalidTimeRange();
    error OrderNotFound();
    error AlreadySettled();
    error OnlyBuyer();
    error OnlyTrainer();
    error ClassAlreadyStarted();
    error ReleaseNotReady();
    error CannotBuyOwnClass();

    // ────────────────────────── Constructor ────────────────────────

    constructor(address _token) {
        REWARD_TOKEN = IERC20(_token);
    }

    // ──────────────────────── External Functions ───────────────────

    /**
     * @notice 클래스 구매 + ERC-20 토큰 예치
     * @param trainer 트레이너 주소
     * @param classHash 클래스 내용의 keccak256 해시
     * @param price 예치할 토큰 수량
     * @param startTime 클래스 시작 시각 (unix timestamp)
     * @param endTime 클래스 종료 시각 (unix timestamp)
     * @return orderId 생성된 주문 ID
     */
    function purchaseClass(address trainer, bytes32 classHash, uint256 price, uint256 startTime, uint256 endTime)
        external
        returns (uint256 orderId)
    {
        if (classHash == bytes32(0)) revert InvalidClassHash();
        if (price == 0) revert InvalidPrice();
        if (startTime >= endTime || endTime <= block.timestamp) revert InvalidTimeRange();
        if (msg.sender == trainer) revert CannotBuyOwnClass();

        orderId = orderCount++;

        orders[orderId] = ClassOrder({
            buyer: msg.sender,
            trainer: trainer,
            classHash: classHash,
            price: price,
            startTime: startTime,
            endTime: endTime,
            settled: false
        });

        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, classHash, price, startTime, endTime);
    }

    /**
     * @notice 구매자가 클래스 확정 → 트레이너에게 즉시 지급 (시간 제한 없음)
     * @param orderId 주문 ID
     */
    function confirmClass(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.settled) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();

        o.settled = true;

        REWARD_TOKEN.safeTransfer(o.trainer, o.price);

        emit ClassConfirmed(orderId, o.trainer, o.price);
    }

    /**
     * @notice 클래스 종료 후 3일이 지나면 누구나 호출하여 트레이너에게 지급
     * @param orderId 주문 ID
     */
    function releasePayment(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.settled) revert AlreadySettled();
        if (block.timestamp < o.endTime + AUTO_RELEASE_DELAY) revert ReleaseNotReady();

        o.settled = true;

        REWARD_TOKEN.safeTransfer(o.trainer, o.price);

        emit PaymentReleased(orderId, o.trainer, o.price);
    }

    /**
     * @notice 구매자가 클래스 시작 전 환불 (예치금 돌려받기)
     * @param orderId 주문 ID
     */
    function refundClass(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.settled) revert AlreadySettled();
        if (msg.sender != o.buyer) revert OnlyBuyer();
        if (block.timestamp >= o.startTime) revert ClassAlreadyStarted();

        o.settled = true;

        REWARD_TOKEN.safeTransfer(o.buyer, o.price);

        emit ClassRefunded(orderId, o.buyer, o.price);
    }

    /**
     * @notice 트레이너가 클래스 시작 전 취소 → 구매자에게 환불
     * @param orderId 주문 ID
     */
    function cancelClass(uint256 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.settled) revert AlreadySettled();
        if (msg.sender != o.trainer) revert OnlyTrainer();
        if (block.timestamp >= o.startTime) revert ClassAlreadyStarted();

        o.settled = true;

        REWARD_TOKEN.safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    // ──────────────────────── View Functions ──────────────────────

    /**
     * @notice 주문 조회
     */
    function getOrder(uint256 orderId)
        external
        view
        returns (
            address buyer,
            address trainer,
            bytes32 classHash,
            uint256 price,
            uint256 startTime,
            uint256 endTime,
            bool settled
        )
    {
        ClassOrder storage o = orders[orderId];
        return (o.buyer, o.trainer, o.classHash, o.price, o.startTime, o.endTime, o.settled);
    }
}
