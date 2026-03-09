// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MarketplaceEscrow
 * @notice 마켓플레이스 에스크로 컨트랙트
 *         EIP-7702(서버 가스 대납 및 Batch 위임 실행) 환경과 완벽히 호환되도록
 *         복잡한 서명 검증 로직 없이 가장 안전하고 심플한 순정 형태로 설계됨.
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
     * @notice 클래스 구매 + 예치
     */
    function purchaseClass(
        address trainer,
        bytes32 classHash,
        uint256 price,
        uint256 startTime,
        uint256 endTime
    ) external returns (uint256 orderId) {
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

        // EIP-7702 Batch 모드라면 이 직전에 approve() 트랜잭션이 한 묶음으로 실행되어 있을 것임.
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), price);

        emit ClassPurchased(orderId, msg.sender, trainer, classHash, price, startTime, endTime);
    }

    /**
     * @notice 구매자가 클래스 확정
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
     * @notice 종료 후 3일 경과, 누구나 자동 호출
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
     * @notice 구매자가 클래스 시작 전 환불
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
     * @notice 트레이너가 클래스 시작 전 취소 → 구매자 환불
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
