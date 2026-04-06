// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";
import {IMarketplaceEscrow} from "../src/interfaces/IMarketplaceEscrow.sol";

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
    uint256 public orderNonce = 1;

    // EIP-7702 Batch Account Simulation
    BatchImplementation public batchImpl;

    function setUp() public {
        buyer = vm.addr(buyerPk);

        token = new MockToken();
        escrow = new MarketplaceEscrow(owner);
        batchImpl = new BatchImplementation();

        token.mint(buyer, 10_000 ether);

        vm.etch(buyer, address(batchImpl).code);

        // 화이트리스트 추가
        vm.prank(owner);
        escrow.updateTokenSupport(address(token), true);
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

        bytes32 callTypehash = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 batchTypehash = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");

        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(callTypehash, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }

        uint256 currentNonce = BatchImplementation(payable(buyer)).txNonce();
        bytes32 structHash = keccak256(abi.encode(batchTypehash, currentNonce, keccak256(abi.encodePacked(callHashes))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        BatchImplementation(payable(buyer)).execute(calls, signature);
    }

    function _purchaseThroughBatch() internal returns (bytes32 orderId) {
        orderId = keccak256(abi.encodePacked("order", orderNonce++));

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);

        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), price)
        });

        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                MarketplaceEscrow.purchaseClass.selector, orderId, address(token), trainer, price
            )
        });

        _executeBatchAsRelayer(calls);
        return orderId;
    }

    // ─────────────────── 구매 및 예치 (Multi-token, 0 Fee) ───────────────────

    function test_PurchaseClass_GaslessBatch() public {
        bytes32 orderId = _purchaseThroughBatch();

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);

        assertEq(o.orderId, orderId);
        assertEq(o.buyer, buyer);
        assertEq(o.trainer, trainer);
        assertEq(o.token, address(token));
        assertEq(o.price, price);
        assertEq(o.state, escrow.STATE_CREATED());

        assertEq(token.balanceOf(address(escrow)), price);
        assertEq(token.balanceOf(buyer), 10_000 ether - price);
    }

    // ─────────────────── 상태 변경 액션들 (직접 호출) ───────────────────

    function _purchaseNative() internal returns (bytes32) {
        bytes32 orderId = keccak256(abi.encodePacked("order", orderNonce++));
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        escrow.purchaseClass(orderId, address(token), trainer, price);
        vm.stopPrank();
        return orderId;
    }

    function test_ConfirmClass() public {
        bytes32 orderId = _purchaseNative();

        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        // 100 ether total to trainer directly
        assertEq(token.balanceOf(trainer), trainerBalBefore + price);

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);
        assertEq(o.state, escrow.STATE_CONFIRMED());
    }

    function test_Fail_ConfirmByNonBuyer() public {
        bytes32 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyBuyer.selector);
        escrow.confirmClass(orderId);
    }

    function test_CancelClass_ByTrainer() public {
        bytes32 orderId = _purchaseNative();

        vm.prank(trainer);
        escrow.cancelClass(orderId);

        // Refund full price to buyer
        assertEq(token.balanceOf(buyer), 10_000 ether);

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);
        assertEq(o.state, escrow.STATE_CANCELLED());
    }

    function test_CancelClass_ByBuyer() public {
        bytes32 orderId = _purchaseNative();

        vm.prank(buyer);
        escrow.cancelClass(orderId);

        assertEq(token.balanceOf(buyer), 10_000 ether);

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);
        assertEq(o.state, escrow.STATE_CANCELLED());
    }

    function test_Fail_CancelByStranger() public {
        bytes32 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyBuyerOrTrainer.selector);
        escrow.cancelClass(orderId);
    }

    function test_Fail_CancelAfterConfirmed() public {
        bytes32 orderId = _purchaseNative();

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        vm.prank(trainer);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.cancelClass(orderId);

        vm.prank(buyer);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.cancelClass(orderId);
    }

    function test_AdminSettle() public {
        bytes32 orderId = _purchaseNative();

        uint256 trainerBalBefore = token.balanceOf(trainer);

        vm.prank(owner);
        escrow.adminSettle(orderId);

        assertEq(token.balanceOf(trainer), trainerBalBefore + price);

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);
        assertEq(o.state, escrow.STATE_ADMIN_SETTLED());
    }

    function test_Fail_AdminSettleByNonOwnerOrRelayer() public {
        bytes32 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyRelayerOrOwner.selector);
        escrow.adminSettle(orderId);
    }

    function test_AdminRefund() public {
        bytes32 orderId = _purchaseNative();

        vm.prank(owner);
        escrow.adminRefund(orderId);

        assertEq(token.balanceOf(buyer), 10_000 ether);

        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(orderId);
        assertEq(o.state, escrow.STATE_ADMIN_REFUNDED());
    }

    function test_Fail_AdminRefundByNonOwner() public {
        bytes32 orderId = _purchaseNative();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyRelayerOrOwner.selector);
        escrow.adminRefund(orderId);
    }

    function test_Fail_PurchaseOwnClass() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);

        bytes32 orderId = keccak256(abi.encodePacked("order", orderNonce++));
        vm.expectRevert(IMarketplaceEscrow.CannotBuyOwnClass.selector);
        escrow.purchaseClass(orderId, address(token), buyer, price);

        vm.stopPrank();
    }

    function test_Fail_AlreadySettled() public {
        bytes32 orderId = _purchaseNative();

        vm.prank(buyer);
        escrow.confirmClass(orderId);

        vm.prank(buyer);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.confirmClass(orderId);

        vm.prank(trainer);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.cancelClass(orderId);

        vm.prank(owner);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.adminSettle(orderId);

        vm.prank(owner);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.adminRefund(orderId);
    }

    // ─────────────────── V2 Upgrade Features ───────────────────

    function test_Fail_UnsupportedToken() public {
        MockToken badToken = new MockToken();
        vm.prank(buyer);
        badToken.mint(buyer, 100 ether);

        bytes32 orderId = keccak256(abi.encodePacked("order", orderNonce++));
        vm.startPrank(buyer);
        badToken.approve(address(escrow), type(uint256).max);

        vm.expectRevert(IMarketplaceEscrow.UnsupportedToken.selector);
        escrow.purchaseClass(orderId, address(badToken), trainer, price);
        vm.stopPrank();
    }

    function test_Fail_OrderAlreadyExists() public {
        bytes32 orderId = _purchaseNative();
        vm.prank(buyer);
        vm.expectRevert(IMarketplaceEscrow.OrderAlreadyExists.selector);
        escrow.purchaseClass(orderId, address(token), trainer, price);
    }

    function test_RelayerFunctions() public {
        // Set up relayer mapping
        vm.prank(owner);
        escrow.updateRelayer(relayer, true);

        bytes32 orderId1 = _purchaseNative();
        bytes32 orderId2 = _purchaseNative();

        // Relayer can execute settle and refund
        vm.prank(relayer);
        escrow.adminSettle(orderId1);

        vm.prank(relayer);
        escrow.adminRefund(orderId2);

        IMarketplaceEscrow.ClassOrder memory o1 = escrow.getOrder(orderId1);
        IMarketplaceEscrow.ClassOrder memory o2 = escrow.getOrder(orderId2);
        assertEq(o1.state, escrow.STATE_ADMIN_SETTLED());
        assertEq(o2.state, escrow.STATE_ADMIN_REFUNDED());
    }

    function test_GetOrders() public {
        bytes32 orderId1 = _purchaseNative();
        bytes32 orderId2 = _purchaseNative();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = orderId1;
        ids[1] = orderId2;

        IMarketplaceEscrow.ClassOrder[] memory qs = escrow.getOrders(ids);
        assertEq(qs.length, 2);
        assertEq(qs[0].orderId, orderId1);
        assertEq(qs[1].orderId, orderId2);
        assertEq(qs[0].state, escrow.STATE_CREATED());
        assertEq(qs[1].state, escrow.STATE_CREATED());
    }
}
