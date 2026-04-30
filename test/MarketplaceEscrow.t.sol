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
    uint256 public signerPk = 0x5EF1;
    address public signerAddr;
    address public trainer = address(2);
    address public stranger = address(3);
    address public owner = address(5);
    address public relayer = address(999);
    uint256 public price = 100 ether;
    uint256 public orderNonce = 1;
    bytes32 private constant _TYPEHASH = keccak256(
        "PurchaseClass(address buyer,bytes32 orderId,address token,address trainer,uint256 price,uint256 nonce,uint256 signedAt)"
    );
    BatchImplementation public batchImpl;

    function setUp() public {
        buyer = vm.addr(buyerPk);
        signerAddr = vm.addr(signerPk);
        token = new MockToken();
        escrow = new MarketplaceEscrow(owner, signerAddr);
        batchImpl = new BatchImplementation();
        token.mint(buyer, 10_000 ether);
        vm.etch(buyer, address(batchImpl).code);
        vm.prank(owner);
        escrow.updateTokenSupport(address(token), true);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MarketplaceEscrow")),
                keccak256(bytes("1")),
                block.chainid,
                address(escrow)
            )
        );
    }

    function _sign(
        uint256 pk,
        address _buyer,
        bytes32 orderId,
        address _tok,
        address _trainer,
        uint256 _price,
        uint256 nonce,
        uint256 signedAt
    ) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(_TYPEHASH, _buyer, orderId, _tok, _trainer, _price, nonce, signedAt));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _execBatch(BatchImplementation.Call[] memory calls) internal {
        bytes32 dom = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BatchAccount")),
                keccak256(bytes("1")),
                block.chainid,
                buyer
            )
        );
        bytes32 ct = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 bt = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");
        bytes32[] memory ch = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            ch[i] = keccak256(abi.encode(ct, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }
        uint256 cn = BatchImplementation(payable(buyer)).txNonce();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(bt, cn, keccak256(abi.encodePacked(ch)))))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        vm.prank(relayer);
        BatchImplementation(payable(buyer)).execute(calls, abi.encodePacked(r, s, v));
    }

    function _buy() internal returns (bytes32) {
        bytes32 id = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, buyer, id, address(token), trainer, price, escrow.nonces(buyer), sat);
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        escrow.purchaseClass(id, address(token), trainer, price, sat, sig);
        vm.stopPrank();
        return id;
    }

    function _buyBatch() internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, buyer, id, address(token), trainer, price, escrow.nonces(buyer), sat);
        BatchImplementation.Call[] memory c = new BatchImplementation.Call[](2);
        c[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), price)
        });
        c[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                MarketplaceEscrow.purchaseClass.selector, id, address(token), trainer, price, sat, sig
            )
        });
        _execBatch(c);
    }

    function test_PurchaseClass_GaslessBatch() public {
        bytes32 id = _buyBatch();
        IMarketplaceEscrow.ClassOrder memory o = escrow.getOrder(id);
        assertEq(o.buyer, buyer);
        assertEq(o.state, escrow.STATE_CREATED());
        assertEq(token.balanceOf(address(escrow)), price);
    }

    function test_ConfirmClass() public {
        bytes32 id = _buy();
        uint256 bal = token.balanceOf(trainer);
        vm.prank(buyer);
        escrow.confirmClass(id);
        assertEq(token.balanceOf(trainer), bal + price);
        assertEq(escrow.getOrder(id).state, escrow.STATE_CONFIRMED());
    }

    function test_Fail_ConfirmByNonBuyer() public {
        bytes32 id = _buy();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyBuyer.selector);
        escrow.confirmClass(id);
    }

    function test_CancelClass_ByBuyer() public {
        bytes32 id = _buy();
        vm.prank(buyer);
        escrow.cancelClass(id);
        assertEq(token.balanceOf(buyer), 10_000 ether);
        assertEq(escrow.getOrder(id).state, escrow.STATE_CANCELLED());
    }

    function test_CancelClass_ByTrainer() public {
        bytes32 id = _buy();
        vm.prank(trainer);
        escrow.cancelClass(id);
        assertEq(token.balanceOf(buyer), 10_000 ether);
    }

    function test_Fail_CancelByStranger() public {
        bytes32 id = _buy();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyBuyerOrTrainer.selector);
        escrow.cancelClass(id);
    }

    function test_AdminSettle() public {
        bytes32 id = _buy();
        uint256 bal = token.balanceOf(trainer);
        vm.prank(owner);
        escrow.adminSettle(id);
        assertEq(token.balanceOf(trainer), bal + price);
        assertEq(escrow.getOrder(id).state, escrow.STATE_ADMIN_SETTLED());
    }

    function test_Fail_AdminSettleByNonOwnerOrRelayer() public {
        bytes32 id = _buy();
        vm.prank(stranger);
        vm.expectRevert(IMarketplaceEscrow.OnlyRelayerOrOwner.selector);
        escrow.adminSettle(id);
    }

    function test_AdminRefund() public {
        bytes32 id = _buy();
        vm.prank(owner);
        escrow.adminRefund(id);
        assertEq(token.balanceOf(buyer), 10_000 ether);
        assertEq(escrow.getOrder(id).state, escrow.STATE_ADMIN_REFUNDED());
    }

    function test_RelayerFunctions() public {
        vm.prank(owner);
        escrow.updateRelayer(relayer, true);
        bytes32 id1 = _buy();
        bytes32 id2 = _buy();
        vm.prank(relayer);
        escrow.adminSettle(id1);
        vm.prank(relayer);
        escrow.adminRefund(id2);
        assertEq(escrow.getOrder(id1).state, escrow.STATE_ADMIN_SETTLED());
        assertEq(escrow.getOrder(id2).state, escrow.STATE_ADMIN_REFUNDED());
    }

    function test_Fail_InvalidSignature() public {
        bytes32 id = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory bad = _sign(0xBAD, buyer, id, address(token), trainer, price, 0, sat);
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IMarketplaceEscrow.InvalidSignature.selector);
        escrow.purchaseClass(id, address(token), trainer, price, sat, bad);
        vm.stopPrank();
    }

    function test_Fail_ExpiredSignature() public {
        bytes32 id = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, buyer, id, address(token), trainer, price, 0, sat);
        vm.warp(block.timestamp + 16 minutes);
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IMarketplaceEscrow.SignatureExpired.selector);
        escrow.purchaseClass(id, address(token), trainer, price, sat, sig);
        vm.stopPrank();
    }

    function test_Fail_SignatureReplay() public {
        bytes32 id1 = keccak256(abi.encodePacked("order", orderNonce++));
        bytes32 id2 = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, buyer, id1, address(token), trainer, price, 0, sat);
        vm.startPrank(buyer);
        token.approve(address(escrow), type(uint256).max);
        escrow.purchaseClass(id1, address(token), trainer, price, sat, sig);
        vm.expectRevert(IMarketplaceEscrow.InvalidSignature.selector);
        escrow.purchaseClass(id2, address(token), trainer, price, sat, sig);
        vm.stopPrank();
    }

    function test_ClaimExpiredRefund() public {
        bytes32 id = _buy();
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(buyer);
        escrow.claimExpiredRefund(id);
        assertEq(token.balanceOf(buyer), bal + price);
        assertEq(escrow.getOrder(id).state, escrow.STATE_DEADLINE_REFUNDED());
    }

    function test_ClaimExpiredRefund_ByAnyone() public {
        bytes32 id = _buy();
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(buyer);
        vm.prank(stranger);
        escrow.claimExpiredRefund(id);
        assertEq(token.balanceOf(buyer), bal + price);
    }

    function test_Fail_ClaimTooEarly() public {
        bytes32 id = _buy();
        vm.expectRevert(IMarketplaceEscrow.DeadlineNotExpired.selector);
        escrow.claimExpiredRefund(id);
    }

    function test_Fail_ConfirmAfterDeadline() public {
        bytes32 id = _buy();
        vm.warp(block.timestamp + 31 days);
        vm.prank(buyer);
        vm.expectRevert(IMarketplaceEscrow.DeadlineExpired.selector);
        escrow.confirmClass(id);
    }

    function test_Fail_AdminSettleAfterDeadline() public {
        bytes32 id = _buy();
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        vm.expectRevert(IMarketplaceEscrow.DeadlineExpired.selector);
        escrow.adminSettle(id);
    }

    function test_Fail_UnsupportedToken() public {
        MockToken bad = new MockToken();
        bad.mint(buyer, 100 ether);
        bytes32 id = keccak256(abi.encodePacked("order", orderNonce++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, buyer, id, address(bad), trainer, price, 0, sat);
        vm.startPrank(buyer);
        bad.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IMarketplaceEscrow.UnsupportedToken.selector);
        escrow.purchaseClass(id, address(bad), trainer, price, sat, sig);
        vm.stopPrank();
    }

    function test_GetOrders() public {
        bytes32 id1 = _buy();
        bytes32 id2 = _buy();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        IMarketplaceEscrow.ClassOrder[] memory r = escrow.getOrders(ids);
        assertEq(r[0].orderId, id1);
        assertEq(r[1].orderId, id2);
    }

    function test_Fail_AlreadySettled() public {
        bytes32 id = _buy();
        vm.prank(buyer);
        escrow.confirmClass(id);
        vm.prank(buyer);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.confirmClass(id);
        vm.prank(owner);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.adminSettle(id);
        vm.prank(owner);
        vm.expectRevert(IMarketplaceEscrow.AlreadySettled.selector);
        escrow.adminRefund(id);
    }
}
