// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10_000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MarketplaceEscrowTest is Test {
    MarketplaceEscrow public escrow;
    MockToken public token;

    uint256 public buyerPk = 0xA11CE;
    address public buyer;
    
    address public trainer = address(2);
    address public stranger = address(3);
    
    // 이 트랜잭션들의 가스비를 낼 임의의 릴레이어 (서버 지갑 역할)
    address public relayer = address(999);

    bytes32 public classHash = keccak256("Cycling Class #1");
    uint256 public price = 100 ether;

    uint256 public startTime;
    uint256 public endTime;

    // EIP-7702 Batch Account Simulation
    BatchImplementation public batchImpl;

    function setUp() public {
        buyer = vm.addr(buyerPk);

        startTime = block.timestamp + 1 days;
        endTime = block.timestamp + 2 days;

        token = new MockToken();
        escrow = new MarketplaceEscrow(address(token));
        batchImpl = new BatchImplementation();

        // 구매자에게 토큰 미리 전송
        token.mint(buyer, 10_000 ether);
        
        // --- EIP-7702 시뮬레이션 환경 구성 ---
        // 실제로는 블록체인 노드 레벨에서 EOA에 코드를 주입하지만,
        // 테스트 환경에서는 사용자 주소(buyer)에 BatchImplementation 코드를 강제로 etdcode 주입하여 흉내냅니다.
        vm.etch(buyer, address(batchImpl).code);
    }

    // ─────────────────────── Batch Execution Helper ───────────────────────

    // 오프체인 서버가 사용자의 서명을 받아 Batch를 실행하는 것을 시뮬레이션
    function _executeBatchAsRelayer(BatchImplementation.Call[] memory calls) internal {
        // EIP-712 도메인 설정 (주입된 코드가 buyer 주소에서 실행되므로 주소는 buyer)
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BatchAccount")),
                keccak256(bytes("1")),
                block.chainid,
                buyer
            )
        );

        // Batch 해시 생성
        bytes32 CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 BATCH_TYPEHASH = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");
        
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }

        uint256 currentNonce = BatchImplementation(payable(buyer)).txNonce();
        bytes32 structHash = keccak256(abi.encode(BATCH_TYPEHASH, currentNonce, keccak256(abi.encodePacked(callHashes))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // 구매자가 서명생성
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // 서버(relayer)가 가스비를 내고 execute 함수 호출
        vm.prank(relayer);
        BatchImplementation(payable(buyer)).execute(calls, signature);
    }

    function _purchaseThroughBatch() internal returns (uint256 orderId) {
        orderId = escrow.orderCount(); // 다음에 생성될 ID
        
        // 2개의 액션을 하나의 Batch로 묶음
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        
        // 1. approve 설정 (에스크로 컨트랙트가 토큰을 빼갈 수 있도록)
        calls[0] = BatchImplementation.Call({
            to: address(token),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), price)
        });

        // 2. 클래스 구매 호출
        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                MarketplaceEscrow.purchaseClass.selector,
                trainer, classHash, price, startTime, endTime
            )
        });

        _executeBatchAsRelayer(calls);
        return orderId;
    }

    // ─────────────────── 구매 및 예치 (100% Gasless Batch) ───────────────────

    function test_PurchaseClass_GaslessBatch() public {
        uint256 orderId = _purchaseThroughBatch();

        // 컨트랙트 상태 검증
        (address b, address t, bytes32 ch, uint256 p, uint256 st, uint256 et, bool settled) = escrow.getOrder(orderId);
        
        assertEq(b, buyer);       // EIP-7702 덕분에 msg.sender가 buyer로 잘 기록됨
        assertEq(t, trainer);
        assertEq(ch, classHash);
        assertEq(p, price);
        assertEq(st, startTime);
        assertEq(et, endTime);
        assertFalse(settled);

        // 토큰 잔고 확인
        assertEq(token.balanceOf(address(escrow)), price);
        assertEq(token.balanceOf(buyer), 10_000 ether - price);
    }

    // ─────────────────── 상태 변경 액션들 (직접 호출) ───────────────────
    // 구매 이후의 액션들도 마찬가지로 Batch를 통해 가스리스로 이루어지게 할 수 있으나,
    // 이 테스트에서는 컨트랙트 순정 로직이 msg.sender 기반으로 잘 돌아가는지 단독 검증합니다.

    function _purchaseNative() internal returns (uint256) {
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        uint256 orderId = escrow.purchaseClass(trainer, classHash, price, startTime, endTime);
        vm.stopPrank();
        return orderId;
    }

    function test_ConfirmClass() public {
        uint256 orderId = _purchaseNative();
        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        assertEq(token.balanceOf(trainer), trainerBalBefore + price);
        (,,,,,,bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_ConfirmByNonBuyer() public {
        uint256 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.OnlyBuyer.selector);
        escrow.confirmClass(orderId);
    }

    function test_RefundClass() public {
        uint256 orderId = _purchaseNative();

        vm.prank(buyer);
        escrow.refundClass(orderId);

        (,,,,,,bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_RefundAfterStart() public {
        uint256 orderId = _purchaseNative();
        vm.warp(startTime);
        
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.ClassAlreadyStarted.selector);
        escrow.refundClass(orderId);
    }

    function test_CancelClass() public {
        uint256 orderId = _purchaseNative();

        vm.prank(trainer);
        escrow.cancelClass(orderId);

        (,,,,,,bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_ReleasePayment() public {
        uint256 orderId = _purchaseNative();

        vm.warp(endTime + 3 days + 1);

        // 누구나 호출 가능
        vm.prank(stranger);
        escrow.releasePayment(orderId);

        (,,,,,,bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }
}
