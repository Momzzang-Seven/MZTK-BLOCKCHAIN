// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10_000 ether);
    }
}

contract MarketplaceEscrowTest is Test {
    MarketplaceEscrow public escrow;
    MockToken public token;

    address public buyer = address(1);
    address public trainer = address(2);
    address public stranger = address(3);

    bytes32 public classHash = keccak256("Yoga Class #1");
    uint256 public price = 100 ether;

    uint256 public startTime;
    uint256 public endTime;

    function setUp() public {
        // 현재 시각 기준 시작·종료 시각 설정
        startTime = block.timestamp + 1 days;
        endTime = block.timestamp + 2 days;

        vm.startPrank(buyer);
        token = new MockToken();
        escrow = new MarketplaceEscrow(address(token));
        token.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────── Helper ───────────────────────

    function _purchase() internal returns (uint256) {
        vm.prank(buyer);
        return escrow.purchaseClass(trainer, classHash, price, startTime, endTime);
    }

    // ─────────────────── 클래스 구매 ───────────────────

    function test_PurchaseClass() public {
        uint256 orderId = _purchase();

        (address b, address t, bytes32 ch, uint256 p, uint256 st, uint256 et, bool settled) = escrow.getOrder(orderId);

        assertEq(b, buyer);
        assertEq(t, trainer);
        assertEq(ch, classHash);
        assertEq(p, price);
        assertEq(st, startTime);
        assertEq(et, endTime);
        assertFalse(settled);

        // 토큰이 에스크로에 예치되었는지 확인
        assertEq(token.balanceOf(address(escrow)), price);
        assertEq(token.balanceOf(buyer), 10_000 ether - price);
    }

    function test_Fail_PurchaseZeroPrice() public {
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.InvalidPrice.selector);
        escrow.purchaseClass(trainer, classHash, 0, startTime, endTime);
    }

    function test_Fail_PurchaseZeroClassHash() public {
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.InvalidClassHash.selector);
        escrow.purchaseClass(trainer, bytes32(0), price, startTime, endTime);
    }

    function test_Fail_PurchasePastEndTime() public {
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.InvalidTimeRange.selector);
        escrow.purchaseClass(trainer, classHash, price, startTime, block.timestamp - 1);
    }

    function test_Fail_PurchaseInvalidTimeRange() public {
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.InvalidTimeRange.selector);
        // startTime >= endTime
        escrow.purchaseClass(trainer, classHash, price, endTime, startTime);
    }

    function test_Fail_PurchaseOwnClass() public {
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.CannotBuyOwnClass.selector);
        escrow.purchaseClass(buyer, classHash, price, startTime, endTime);
    }

    // ─────────────────── 구매자 확정 ───────────────────

    function test_ConfirmClass() public {
        uint256 orderId = _purchase();
        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        // 트레이너에게 지급 확인
        assertEq(token.balanceOf(trainer), trainerBalBefore + price);
        assertEq(token.balanceOf(address(escrow)), 0);

        // settled 상태 확인
        (,,,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_ConfirmByNonBuyer() public {
        uint256 orderId = _purchase();

        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.OnlyBuyer.selector);
        escrow.confirmClass(orderId);
    }

    function test_Fail_DoubleConfirm() public {
        uint256 orderId = _purchase();

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.confirmClass(orderId);
    }

    // ─────────────────── 자동 정산 (3일 경과) ───────────────────

    function test_ReleaseAfterDelay() public {
        uint256 orderId = _purchase();
        uint256 trainerBalBefore = token.balanceOf(trainer);

        // endTime + 3일 경과
        vm.warp(endTime + 3 days + 1);

        vm.prank(stranger); // 누구나 호출 가능
        escrow.releasePayment(orderId);

        assertEq(token.balanceOf(trainer), trainerBalBefore + price);
        assertEq(token.balanceOf(address(escrow)), 0);

        (,,,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_ReleaseTooEarly() public {
        uint256 orderId = _purchase();

        // endTime + 2일 (아직 3일 안됨)
        vm.warp(endTime + 2 days);

        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.ReleaseNotReady.selector);
        escrow.releasePayment(orderId);
    }

    function test_Fail_ReleaseAlreadySettled() public {
        uint256 orderId = _purchase();

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        vm.warp(endTime + 3 days + 1);

        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.releasePayment(orderId);
    }

    // ─────────────────── 구매자 환불 ───────────────────

    function test_RefundBeforeStart() public {
        uint256 orderId = _purchase();
        uint256 buyerBalBefore = token.balanceOf(buyer);

        vm.prank(buyer);
        escrow.refundClass(orderId);

        // 환불 확인
        assertEq(token.balanceOf(buyer), buyerBalBefore + price);
        assertEq(token.balanceOf(address(escrow)), 0);

        (,,,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_RefundAfterStart() public {
        uint256 orderId = _purchase();

        // 클래스 시작 시각 이후로 시간 이동
        vm.warp(startTime);

        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.ClassAlreadyStarted.selector);
        escrow.refundClass(orderId);
    }

    function test_Fail_RefundByNonBuyer() public {
        uint256 orderId = _purchase();

        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.OnlyBuyer.selector);
        escrow.refundClass(orderId);
    }

    function test_Fail_RefundAlreadySettled() public {
        uint256 orderId = _purchase();

        vm.prank(buyer);
        escrow.refundClass(orderId);

        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.refundClass(orderId);
    }

    // ─────────────────── 트레이너 취소 ───────────────────

    function test_CancelBeforeStart() public {
        uint256 orderId = _purchase();
        uint256 buyerBalBefore = token.balanceOf(buyer);

        vm.prank(trainer);
        escrow.cancelClass(orderId);

        // 구매자에게 환불 확인
        assertEq(token.balanceOf(buyer), buyerBalBefore + price);
        assertEq(token.balanceOf(address(escrow)), 0);

        (,,,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_CancelAfterStart() public {
        uint256 orderId = _purchase();

        vm.warp(startTime);

        vm.prank(trainer);
        vm.expectRevert(MarketplaceEscrow.ClassAlreadyStarted.selector);
        escrow.cancelClass(orderId);
    }

    function test_Fail_CancelByNonTrainer() public {
        uint256 orderId = _purchase();

        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.OnlyTrainer.selector);
        escrow.cancelClass(orderId);
    }

    function test_Fail_CancelAlreadySettled() public {
        uint256 orderId = _purchase();

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        vm.prank(trainer);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.cancelClass(orderId);
    }
}
