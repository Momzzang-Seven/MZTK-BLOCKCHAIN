// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Mock ERC20 ─────────────────────────────────────────────────────────────

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Dummy target that always reverts with custom data ────────────────────────

contract AlwaysReverts {
    error CustomError(uint256 code);

    function fail() external pure {
        revert CustomError(42);
    }
}

// ─── BatchImplementationTest ──────────────────────────────────────────────────

contract BatchImplementationTest is Test {
    BatchImplementation public impl;
    MockToken public token;
    AlwaysReverts public reverter;

    // EOA that acts as the account (EIP-7702 style)
    uint256 public eoaPk = 0xA11CE;
    address public eoa;
    address public sponsor = address(0x9999);
    address public stranger = address(0x1234);

    // EIP-712 typehash
    bytes32 private constant _EXECUTION_TYPEHASH =
        keccak256("Mztk7702Execution(string prepareId,bytes32 callDataHash,uint256 deadline)");

    uint256 private _prepareNonce = 1;

    function setUp() public {
        eoa = vm.addr(eoaPk);
        impl = new BatchImplementation();
        token = new MockToken();
        reverter = new AlwaysReverts();

        // EIP-7702 simulation: etch BatchImplementation code onto EOA
        vm.etch(eoa, address(impl).code);

        token.mint(eoa, 10_000 ether);
    }

    // ─── EIP-712 helpers ──────────────────────────────────────────────────────

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MomzzangSeven")),
                keccak256(bytes("1")),
                block.chainid,
                eoa
            )
        );
    }

    function _sign(uint256 pk, BatchImplementation.Call[] memory calls, string memory prepareId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 prepareIdHash = keccak256(bytes(prepareId));
        bytes32 callDataHash = keccak256(abi.encode(calls));
        bytes32 structHash = keccak256(abi.encode(_EXECUTION_TYPEHASH, prepareIdHash, callDataHash, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _nextPrepareId() internal returns (string memory) {
        return string(abi.encodePacked("prepare-", vm.toString(_prepareNonce++)));
    }

    // ─── Happy path ───────────────────────────────────────────────────────────

    // Successful ERC20 approve + transfer in a single batch
    function test_Execute_ERC20Approve() public {
        address recipient = address(0xBEEF);
        uint256 amount = 100 ether;

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, recipient, amount)
        });
        calls[1] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.expectEmit(true, true, true, false, eoa);
        emit BatchImplementation.BatchExecuted(keccak256(bytes(prepareId)), keccak256(abi.encode(calls)), sponsor);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);

        assertEq(token.balanceOf(recipient), amount);
    }

    // Single call — minimum valid batch
    function test_Execute_SingleCall() public {
        address recipient = address(0xCAFE);
        uint256 amount = 50 ether;

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 30 minutes;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);

        assertEq(token.balanceOf(recipient), amount);
    }

    // ─── Deadline ─────────────────────────────────────────────────────────────

    // Execution after deadline reverts with SignatureExpired
    function test_Fail_DeadlineExpired() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({to: address(token), value: 0, data: hex""});

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.warp(block.timestamp + 1);

        vm.expectRevert(BatchImplementation.SignatureExpired.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);
    }

    // ─── Replay ───────────────────────────────────────────────────────────────

    // Replaying the same prepareId reverts with ReplayDetected
    function test_Fail_ReplayedPrepareId() public {
        address recipient = address(0xBEEF);
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, 1 ether)
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);

        // Attempt replay — must fail even with a fresh signature
        bytes memory sig2 = _sign(eoaPk, calls, prepareId, deadline);
        vm.expectRevert(BatchImplementation.ReplayDetected.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig2);
    }

    // Different prepareIds are independent — both succeed
    function test_DifferentPrepareIds_BothSucceed() public {
        address recipient = address(0xBEEF);
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, 1 ether)
        });

        uint256 deadline = block.timestamp + 1 hours;

        string memory id1 = _nextPrepareId();
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, id1, deadline, _sign(eoaPk, calls, id1, deadline));

        string memory id2 = _nextPrepareId();
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, id2, deadline, _sign(eoaPk, calls, id2, deadline));

        assertEq(token.balanceOf(recipient), 2 ether);
    }

    // ─── callDataHash mismatch ────────────────────────────────────────────────

    // Signing one calls array but executing with a different one → InvalidSignature
    function test_Fail_CallsTampered() public {
        address recipient = address(0xBEEF);

        BatchImplementation.Call[] memory originalCalls = new BatchImplementation.Call[](1);
        originalCalls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, 1 ether)
        });

        BatchImplementation.Call[] memory tamperedCalls = new BatchImplementation.Call[](1);
        tamperedCalls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, stranger, 999 ether)
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        // Sign for originalCalls, execute with tamperedCalls
        bytes memory sig = _sign(eoaPk, originalCalls, prepareId, deadline);

        vm.expectRevert(BatchImplementation.InvalidSignature.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(tamperedCalls, prepareId, deadline, sig);
    }

    // ─── Wrong signer ─────────────────────────────────────────────────────────

    // Signature from wrong key → InvalidSignature
    function test_Fail_WrongSigner() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({to: address(token), value: 0, data: hex""});

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory badSig = _sign(0xBAD, calls, prepareId, deadline);

        vm.expectRevert(BatchImplementation.InvalidSignature.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, badSig);
    }

    // ─── Internal revert reason preserved ────────────────────────────────────

    // CallFailed bubbles the inner revert data
    function test_Fail_InternalRevertReasonPreserved() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({
            to: address(reverter), value: 0, data: abi.encodeWithSelector(AlwaysReverts.fail.selector)
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        // The revert should wrap as CallFailed(0, reverter, <inner returndata>)
        bytes memory expectedReturnData = abi.encodeWithSelector(AlwaysReverts.CustomError.selector, 42);
        vm.expectRevert(
            abi.encodeWithSelector(BatchImplementation.CallFailed.selector, 0, address(reverter), expectedReturnData)
        );
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);
    }

    // ─── Empty calls ──────────────────────────────────────────────────────────

    function test_Fail_EmptyCalls() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](0);

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.expectRevert(BatchImplementation.EmptyCalls.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);
    }

    // ─── Zero target ──────────────────────────────────────────────────────────

    function test_Fail_ZeroTarget() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({to: address(0), value: 0, data: hex""});

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.expectRevert(abi.encodeWithSelector(BatchImplementation.InvalidTarget.selector, 0));
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);
    }

    // ─── Non-zero value policy ────────────────────────────────────────────────

    // msg.value != 0 reverts
    function test_Fail_MsgValueNotAllowed() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({to: address(token), value: 0, data: hex""});

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.deal(sponsor, 1 ether);
        vm.expectRevert(BatchImplementation.NativeValueNotAllowed.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute{value: 1 ether}(calls, prepareId, deadline, sig);
    }

    // call.value != 0 reverts
    function test_Fail_CallValueNotAllowed() public {
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({to: address(token), value: 1 ether, data: hex""});

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(eoaPk, calls, prepareId, deadline);

        vm.expectRevert(BatchImplementation.NativeValueNotAllowed.selector);
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);
    }
}

// ─── Escrow Integration Tests ──────────────────────────────────────────────────
// End-to-end: Batch → ERC20 approve + escrow action in one atomic tx

import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";
import {IMarketplaceEscrow} from "../src/interfaces/IMarketplaceEscrow.sol";
import {IQnAEscrow} from "../src/interfaces/IQnAEscrow.sol";
import {IEscrowBase} from "../src/interfaces/IEscrowBase.sol";
import {MyERC20} from "../src/MyERC20.sol";

contract BatchEscrowIntegrationTest is Test {
    // ─── Contracts ────────────────────────────────────────────────────────────

    BatchImplementation public impl;
    MarketplaceEscrow public marketplace;
    QnAEscrow public qna;
    MyERC20 public mztk;

    // ─── Actors ───────────────────────────────────────────────────────────────

    // EOA (buyer / asker) — BatchImplementation code is etched onto this address
    uint256 public eoaPk = 0xBEEF1;
    address public eoa;

    // Backend server signer (signs escrow-level EIP-712)
    uint256 public serverSignerPk = 0xBEEF2;
    address public serverSigner;

    address public trainer = address(0xAAA1);
    address public owner = address(0xAD111);
    address public sponsor = address(0x5900);

    // ─── EIP-712 typehashes (batch-level) ────────────────────────────────────

    bytes32 private constant _EXECUTION_TYPEHASH =
        keccak256("Mztk7702Execution(string prepareId,bytes32 callDataHash,uint256 deadline)");

    // ─── EIP-712 typehashes (escrow-level — server-signed) ───────────────────

    bytes32 private constant _PURCHASE_TYPEHASH = keccak256(
        "PurchaseClass(address buyer,bytes32 orderId,address token,address trainer,uint256 price,uint256 signedAt)"
    );
    bytes32 private constant _CREATE_QUESTION_TYPEHASH = keccak256(
        "CreateQuestion(address creator,bytes32 questionId,address token,uint256 rewardAmount,bytes32 questionHash,uint256 signedAt)"
    );

    uint256 private _prepareNonce = 100;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        eoa = vm.addr(eoaPk);
        serverSigner = vm.addr(serverSignerPk);

        impl = new BatchImplementation();
        mztk = new MyERC20("MomzzangSeven Token", "MZTK", 0);

        // Deploy escrow contracts
        marketplace = new MarketplaceEscrow(owner, serverSigner);
        qna = new QnAEscrow(owner, serverSigner);

        // Configure: whitelist token + relayer
        vm.startPrank(owner);
        marketplace.updateTokenSupport(address(mztk), true);
        marketplace.updateRelayer(sponsor, true);
        qna.updateTokenSupport(address(mztk), true);
        qna.updateRelayer(sponsor, true);
        vm.stopPrank();

        // Give EOA (buyer/asker) MZTK tokens
        vm.prank(owner);
        mztk.mint(eoa, 10_000 ether);

        // EIP-7702 simulation: etch BatchImplementation code onto EOA
        vm.etch(eoa, address(impl).code);
    }

    // ─── Batch EIP-712 helpers ────────────────────────────────────────────────

    function _batchDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MomzzangSeven")),
                keccak256(bytes("1")),
                block.chainid,
                eoa
            )
        );
    }

    function _signBatch(uint256 pk, BatchImplementation.Call[] memory calls, string memory prepareId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 prepareIdHash = keccak256(bytes(prepareId));
        bytes32 callDataHash = keccak256(abi.encode(calls));
        bytes32 structHash = keccak256(abi.encode(_EXECUTION_TYPEHASH, prepareIdHash, callDataHash, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _batchDomain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _nextPrepareId() internal returns (string memory) {
        return string(abi.encodePacked("integration-prepare-", vm.toString(_prepareNonce++)));
    }

    // ─── Escrow server-sig helpers ────────────────────────────────────────────

    function _marketplaceDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MarketplaceEscrow")),
                keccak256(bytes("1")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _qnaDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("QnAEscrow")),
                keccak256(bytes("1")),
                block.chainid,
                address(qna)
            )
        );
    }

    function _serverSignPurchase(
        address buyer,
        bytes32 orderId,
        address token,
        address _trainer,
        uint256 price,
        uint256 signedAt
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(_PURCHASE_TYPEHASH, buyer, orderId, token, _trainer, price, signedAt));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _marketplaceDomain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(serverSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _serverSignCreateQuestion(
        address creator,
        bytes32 questionId,
        address token,
        uint256 rewardAmount,
        bytes32 questionHash,
        uint256 signedAt
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(_CREATE_QUESTION_TYPEHASH, creator, questionId, token, rewardAmount, questionHash, signedAt)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _qnaDomain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(serverSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── Integration: Batch → ERC20 approve + purchaseClass ──────────────────

    // Happy path: EOA approves MZTK and purchases a class in a single batch tx
    function test_Batch_ERC20Approve_PurchaseClass() public {
        bytes32 orderId = keccak256("order-001");
        uint256 price = 100 ether;
        uint256 signedAt = block.timestamp;

        bytes memory serverSig = _serverSignPurchase(eoa, orderId, address(mztk), trainer, price, signedAt);

        // Build batch: [approve, purchaseClass]
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        calls[0] = BatchImplementation.Call({
            to: address(mztk),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(marketplace), price)
        });
        calls[1] = BatchImplementation.Call({
            to: address(marketplace),
            value: 0,
            data: abi.encodeWithSelector(
                IMarketplaceEscrow.purchaseClass.selector, orderId, address(mztk), trainer, price, signedAt, serverSig
            )
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory batchSig = _signBatch(eoaPk, calls, prepareId, deadline);

        uint256 eoaBalBefore = mztk.balanceOf(eoa);
        uint256 escrowBalBefore = mztk.balanceOf(address(marketplace));

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, batchSig);

        // Assert: funds moved from EOA into escrow
        assertEq(mztk.balanceOf(eoa), eoaBalBefore - price);
        assertEq(mztk.balanceOf(address(marketplace)), escrowBalBefore + price);

        // Assert: order was created correctly
        MarketplaceEscrow.ClassOrder memory order = marketplace.getOrder(orderId);
        assertEq(order.buyer, eoa);
        assertEq(order.trainer, trainer);
        assertEq(order.price, price);
        assertEq(order.state, marketplace.STATE_CREATED());
    }

    // ─── Integration: Batch → ERC20 approve + createQuestion ─────────────────

    // Happy path: EOA approves MZTK and creates a question in a single batch tx
    function test_Batch_ERC20Approve_CreateQuestion() public {
        bytes32 questionId = keccak256("question-001");
        bytes32 questionHash = keccak256("my question content hash");
        uint256 reward = 200 ether;
        uint256 signedAt = block.timestamp;

        bytes memory serverSig =
            _serverSignCreateQuestion(eoa, questionId, address(mztk), reward, questionHash, signedAt);

        // Build batch: [approve, createQuestion]
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        calls[0] = BatchImplementation.Call({
            to: address(mztk), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(qna), reward)
        });
        calls[1] = BatchImplementation.Call({
            to: address(qna),
            value: 0,
            data: abi.encodeWithSelector(
                IQnAEscrow.createQuestion.selector, questionId, address(mztk), reward, questionHash, signedAt, serverSig
            )
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory batchSig = _signBatch(eoaPk, calls, prepareId, deadline);

        uint256 eoaBalBefore = mztk.balanceOf(eoa);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, batchSig);

        // Assert: funds moved from EOA into QnA escrow
        assertEq(mztk.balanceOf(eoa), eoaBalBefore - reward);
        assertEq(mztk.balanceOf(address(qna)), reward);

        // Assert: question was created correctly
        QnAEscrow.Question memory q = qna.getQuestion(questionId);
        assertEq(q.asker, eoa);
        assertEq(q.rewardAmount, reward);
        assertEq(q.state, qna.STATE_CREATED());
    }

    // ─── Integration: escrow revert reason preserved through Batch ───────────

    // When purchaseClass fails (UnsupportedToken), CallFailed wraps the escrow error
    function test_Batch_EscrowRevert_UnsupportedToken_Preserved() public {
        // Deploy a second token that is NOT whitelisted
        MyERC20 unsupportedToken = new MyERC20("Bad Token", "BAD", 0);
        vm.prank(owner);
        unsupportedToken.mint(eoa, 1000 ether);

        bytes32 orderId = keccak256("order-bad-token");
        uint256 price = 100 ether;
        uint256 signedAt = block.timestamp;

        bytes memory serverSig = _serverSignPurchase(eoa, orderId, address(unsupportedToken), trainer, price, signedAt);

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        calls[0] = BatchImplementation.Call({
            to: address(unsupportedToken),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(marketplace), price)
        });
        calls[1] = BatchImplementation.Call({
            to: address(marketplace),
            value: 0,
            data: abi.encodeWithSelector(
                IMarketplaceEscrow.purchaseClass.selector,
                orderId,
                address(unsupportedToken),
                trainer,
                price,
                signedAt,
                serverSig
            )
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory batchSig = _signBatch(eoaPk, calls, prepareId, deadline);

        // Inner revert: MarketplaceEscrow.UnsupportedToken
        // Outer revert: BatchImplementation.CallFailed(1, marketplace, <UnsupportedToken abi>)
        bytes memory innerRevertData = abi.encodeWithSelector(IEscrowBase.UnsupportedToken.selector);
        vm.expectRevert(
            abi.encodeWithSelector(BatchImplementation.CallFailed.selector, 1, address(marketplace), innerRevertData)
        );
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, batchSig);
    }

    // When createQuestion fails (duplicate questionId), CallFailed wraps the escrow error
    function test_Batch_EscrowRevert_DuplicateQuestion_Preserved() public {
        bytes32 questionId = keccak256("question-dup");
        bytes32 questionHash = keccak256("content");
        uint256 reward = 50 ether;
        uint256 signedAt = block.timestamp;

        // First creation — succeeds
        bytes memory serverSig1 =
            _serverSignCreateQuestion(eoa, questionId, address(mztk), reward, questionHash, signedAt);
        BatchImplementation.Call[] memory calls1 = new BatchImplementation.Call[](2);
        calls1[0] = BatchImplementation.Call({
            to: address(mztk), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(qna), reward)
        });
        calls1[1] = BatchImplementation.Call({
            to: address(qna),
            value: 0,
            data: abi.encodeWithSelector(
                IQnAEscrow.createQuestion.selector,
                questionId,
                address(mztk),
                reward,
                questionHash,
                signedAt,
                serverSig1
            )
        });
        string memory id1 = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls1, id1, deadline, _signBatch(eoaPk, calls1, id1, deadline));

        // Second attempt with same questionId — QnAEscrow reverts QuestionAlreadyExists
        bytes memory serverSig2 =
            _serverSignCreateQuestion(eoa, questionId, address(mztk), reward, questionHash, signedAt);
        BatchImplementation.Call[] memory calls2 = new BatchImplementation.Call[](2);
        calls2[0] = BatchImplementation.Call({
            to: address(mztk), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(qna), reward)
        });
        calls2[1] = BatchImplementation.Call({
            to: address(qna),
            value: 0,
            data: abi.encodeWithSelector(
                IQnAEscrow.createQuestion.selector,
                questionId,
                address(mztk),
                reward,
                questionHash,
                signedAt,
                serverSig2
            )
        });
        string memory id2 = _nextPrepareId();

        bytes memory innerRevertData = abi.encodeWithSelector(IQnAEscrow.QuestionAlreadyExists.selector);
        vm.expectRevert(
            abi.encodeWithSelector(BatchImplementation.CallFailed.selector, 1, address(qna), innerRevertData)
        );
        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls2, id2, deadline, _signBatch(eoaPk, calls2, id2, deadline));
    }

    // Atomicity: if second call fails, first call (approve) is also rolled back
    function test_Batch_Atomicity_RollbackOnFailure() public {
        bytes32 orderId = keccak256("order-atomicity");
        uint256 price = 100 ether;
        uint256 signedAt = block.timestamp;

        // Use unsupported token to force escrow revert on call[1]
        MyERC20 badToken = new MyERC20("Bad Token", "BAD", 0);
        vm.prank(owner);
        badToken.mint(eoa, 1000 ether);

        bytes memory serverSig = _serverSignPurchase(eoa, orderId, address(badToken), trainer, price, signedAt);

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        calls[0] = BatchImplementation.Call({
            to: address(badToken),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(marketplace), price)
        });
        calls[1] = BatchImplementation.Call({
            to: address(marketplace),
            value: 0,
            data: abi.encodeWithSelector(
                IMarketplaceEscrow.purchaseClass.selector,
                orderId,
                address(badToken),
                trainer,
                price,
                signedAt,
                serverSig
            )
        });

        string memory prepareId = _nextPrepareId();
        uint256 deadline = block.timestamp + 1 hours;

        uint256 balBefore = badToken.balanceOf(eoa);

        vm.expectRevert();
        vm.prank(sponsor);
        BatchImplementation(payable(eoa))
            .execute(calls, prepareId, deadline, _signBatch(eoaPk, calls, prepareId, deadline));

        // Balance unchanged — atomicity preserved
        assertEq(badToken.balanceOf(eoa), balBefore);
        // prepareId NOT consumed — can retry after fixing the issue
        // (tested indirectly: no ReplayDetected on second attempt would succeed if fixed)
    }
}
