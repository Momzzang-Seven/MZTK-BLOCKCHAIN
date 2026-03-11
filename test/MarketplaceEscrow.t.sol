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
    address public owner = address(5);
    address public relayer = address(999);

    uint256 public price = 100 ether;

    // EIP-7702 Batch Account Simulation
    BatchImplementation public batchImpl;

    function setUp() public {
        buyer = vm.addr(buyerPk);

        token = new MockToken();
        escrow = new MarketplaceEscrow(owner);
        batchImpl = new BatchImplementation();

        token.mint(buyer, 10_000 ether);

        vm.etch(buyer, address(batchImpl).code);
    }

    // ─────────────────────── Batch Execution Helper ───────────────────────

    function _executeBatchAsRelayer(BatchImplementation.Call[] memory calls) internal {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BatchAccount")),
                keccak256(bytes("1")),
                block.chainid,
                buyer
            )
        );

        bytes32 CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 BATCH_TYPEHASH = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");

        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }

        uint256 currentNonce = BatchImplementation(payable(buyer)).txNonce();
        bytes32 structHash =
            keccak256(abi.encode(BATCH_TYPEHASH, currentNonce, keccak256(abi.encodePacked(callHashes))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        BatchImplementation(payable(buyer)).execute(calls, signature);
    }

    function _purchaseThroughBatch() internal returns (uint256 orderId) {
        orderId = escrow.orderCount();

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);

        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), price)
        });

        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                MarketplaceEscrow.purchaseClass.selector, address(token), trainer, price
            )
        });

        _executeBatchAsRelayer(calls);
        return orderId;
    }

    // ─────────────────── 구매 및 예치 (Multi-token, 0 Fee) ───────────────────

    function test_PurchaseClass_GaslessBatch() public {
        uint256 orderId = _purchaseThroughBatch();

        (address b, address t, address tk, uint256 p, bool settled) = escrow.getOrder(orderId);

        assertEq(b, buyer);
        assertEq(t, trainer);
        assertEq(tk, address(token));
        assertEq(p, price);
        assertFalse(settled);

        assertEq(token.balanceOf(address(escrow)), price);
        assertEq(token.balanceOf(buyer), 10_000 ether - price);
    }

    // ─────────────────── 상태 변경 액션들 (직접 호출) ───────────────────

    function _purchaseNative() internal returns (uint256) {
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        uint256 orderId = escrow.purchaseClass(address(token), trainer, price);
        vm.stopPrank();
        return orderId;
    }

    function test_ConfirmClass() public {
        uint256 orderId = _purchaseNative();

        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        // 100 ether total to trainer directly
        assertEq(token.balanceOf(trainer), trainerBalBefore + price);

        (,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }

    function test_Fail_ConfirmByNonBuyer() public {
        uint256 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(MarketplaceEscrow.OnlyBuyer.selector);
        escrow.confirmClass(orderId);
    }

    function test_CancelClass() public {
        uint256 orderId = _purchaseNative();

        vm.prank(trainer);
        escrow.cancelClass(orderId);

        // Refund full price to buyer
        assertEq(token.balanceOf(buyer), 10_000 ether); // 원래 잔고 롤백

        (,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }
    
    function test_Fail_CancelByNonTrainer() public {
        uint256 orderId = _purchaseNative();
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.OnlyTrainer.selector);
        escrow.cancelClass(orderId);
    }

    function test_AdminSettle() public {
        uint256 orderId = _purchaseNative();

        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(owner);
        escrow.adminSettle(orderId);

        assertEq(token.balanceOf(trainer), trainerBalBefore + price);

        (,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }
    
    function test_Fail_AdminSettleByNonOwner() public {
        uint256 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        escrow.adminSettle(orderId);
    }

    function test_AdminRefund() public {
        uint256 orderId = _purchaseNative();

        vm.prank(owner);
        escrow.adminRefund(orderId);

        assertEq(token.balanceOf(buyer), 10_000 ether);

        (,,,, bool settled) = escrow.getOrder(orderId);
        assertTrue(settled);
    }
    
    function test_Fail_AdminRefundByNonOwner() public {
        uint256 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        escrow.adminRefund(orderId);
    }
    
    function test_Fail_PurchaseOwnClass() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        
        vm.expectRevert(MarketplaceEscrow.CannotBuyOwnClass.selector);
        escrow.purchaseClass(address(token), buyer, price);
        
        vm.stopPrank();
    }
    
    function test_Fail_AlreadySettled() public {
        uint256 orderId = _purchaseNative();
        
        vm.prank(buyer);
        escrow.confirmClass(orderId);
        
        vm.prank(buyer);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.confirmClass(orderId);
        
        vm.prank(trainer);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.cancelClass(orderId);
        
        vm.prank(owner);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.adminSettle(orderId);
        
        vm.prank(owner);
        vm.expectRevert(MarketplaceEscrow.AlreadySettled.selector);
        escrow.adminRefund(orderId);
    }
}
