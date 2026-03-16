// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MarketplaceEscrow (V2.1 - Secure & Optimized)
 * @notice 마켓플레이스 에스크로 컨트랙트
 *     - 시간(Time) 제약 제거 및 오프체인 스케줄링 의존
 *     - UUID-based bytes32 OrderID 적용으로 멱등성 보장
 *     - 화이트리스트 토큰 지원으로 Fee-on-Transfer 리스크 회피
 *     - 스토리지 패킹 적용으로 가스 최적화
 *     - Relayer 및 일괄 처리(Batch) 도입으로 엔터프라이즈 운영 지원
 */
contract MarketplaceEscrow is Ownable {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Types ────────────────────────────

    struct ClassOrder {
        uint256 price;     // Slot 0
        address token;     // Slot 1
        bool isSettled;    // Slot 1 (Packed with token)
        address buyer;     // Slot 2
        address trainer;   // Slot 3
    }

    // ──────────────────────────── State ────────────────────────────

    /// @dev orderId (from DB UUID) => ClassOrder
    mapping(bytes32 => ClassOrder) public orders;
    
    /// @dev Supported whitelist tokens
    mapping(address => bool) public isSupportedToken;
    
    /// @dev Outbox batch workers / relayers allowed to execute Settle/Refund
    mapping(address => bool) public isRelayer;

    // ──────────────────────────── Events ───────────────────────────

    event ClassPurchased(bytes32 indexed orderId, address indexed buyer, address indexed trainer, address token, uint256 price);
    event ClassConfirmed(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event ClassCancelled(bytes32 indexed orderId, address indexed buyer, uint256 price);
    event AdminSettled(bytes32 indexed orderId, address indexed trainer, uint256 price);
    event AdminRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);
    
    event TokenSupportUpdated(address indexed token, bool isSupported);
    event RelayerUpdated(address indexed relayer, bool isAuthorized);

    // ──────────────────────────── Errors ───────────────────────────

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

    // ────────────────────────── Modifiers ──────────────────────────

    modifier onlyRelayerOrOwner() {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
        _;
    }

    // ────────────────────────── Constructor ────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ──────────────────────── Admin Config ─────────────────────────

    /**
     * @notice 지원하는 결제 토큰 화이트리스트 갱신
     */
    function updateTokenSupport(address token, bool isSupported) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    /**
     * @notice 백엔드 Outbox Worker (Relayer) 권한 갱신
     */
    function updateRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    // ──────────────────────── External Functions ───────────────────

    /**
     * @notice 구매자(Buyer): 클래스 대금 예치 (멱등성 보장)
     * @param orderId 오프체인 DB에서 발급된 고유 UUID 해시
     * @param token 예치할 ERC-20 토큰 주소 (화이트리스트 필요)
     * @param trainer 클래스 운영자(판매자) 지갑 주소
     * @param price 예치할 금액
     */
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

    /**
     * @notice 구매자(Buyer): 클래스 확정 및 트레이너에게 정산
     */
    function confirmClass(bytes32 orderId) external {
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
    function cancelClass(bytes32 orderId) external {
        ClassOrder storage o = orders[orderId];

        if (o.buyer == address(0)) revert OrderNotFound();
        if (o.isSettled) revert AlreadySettled();
        if (msg.sender != o.trainer) revert OnlyTrainer();

        o.isSettled = true;

        IERC20(o.token).safeTransfer(o.buyer, o.price);

        emit ClassCancelled(orderId, o.buyer, o.price);
    }

    /**
     * @notice 관리자/릴레이어: 조건/분쟁 시 트레이너에게 강제 정산
     */
    function adminSettle(bytes32 orderId) external onlyRelayerOrOwner {
        _adminSettle(orderId);
    }

    /**
     * @notice 관리자/릴레이어: 정산 일괄(Batch) 처리
     */
    function batchAdminSettle(bytes32[] calldata orderIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _adminSettle(orderIds[i]);
        }
    }

    /**
     * @notice 관리자/릴레이어: 타임아웃/분쟁/정원 초과 시 구매자에게 강제 환불
     */
    function adminRefund(bytes32 orderId) external onlyRelayerOrOwner {
        _adminRefund(orderId);
    }

    /**
     * @notice 관리자/릴레이어: 환불 일괄(Batch) 처리 
     */
    function batchAdminRefund(bytes32[] calldata orderIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _adminRefund(orderIds[i]);
        }
    }

    // ──────────────────────── Internal Functions ───────────────────

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

    // ──────────────────────── View Functions ──────────────────────

    function getOrder(bytes32 orderId) external view returns (ClassOrder memory) {
        return orders[orderId];
    }
}
