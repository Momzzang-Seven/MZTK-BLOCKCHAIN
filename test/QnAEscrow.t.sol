// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract QnAEscrowTest is Test {
    QnAEscrow public escrow;
    MockToken public token;

    uint256 public askerPk = 0xA11CE;
    address public asker;

    address public responder = address(2);
    address public stranger = address(3);
    address public owner = address(5);
    address public relayer = address(999);

    bytes32 public questionHash = keccak256("What is Solidity?");
    bytes32 public answerHash = keccak256("Solidity is a smart contract language.");
    uint256 public reward = 100 ether;
    uint256 public qNonce = 1;
    uint256 public aNonce = 1;

    // EIP-7702 Batch Account Simulation
    BatchImplementation public batchImpl;

    function setUp() public {
        asker = vm.addr(askerPk);

        token = new MockToken();
        escrow = new QnAEscrow(owner);
        batchImpl = new BatchImplementation();

        token.mint(asker, 10000 ether);

        vm.etch(asker, address(batchImpl).code);

        // WhiteList Update
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
                asker
            )
        );

        bytes32 CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 BATCH_TYPEHASH = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");

        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }

        uint256 currentNonce = BatchImplementation(payable(asker)).txNonce();
        bytes32 structHash =
            keccak256(abi.encode(BATCH_TYPEHASH, currentNonce, keccak256(abi.encodePacked(callHashes))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(askerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        BatchImplementation(payable(asker)).execute(calls, signature);
    }

    function _createQuestionThroughBatch() internal returns (bytes32 qId) {
        qId = keccak256(abi.encodePacked("question", qNonce++));

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);

        calls[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), reward)
        });

        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(QnAEscrow.createQuestion.selector, qId, address(token), questionHash, reward)
        });

        _executeBatchAsRelayer(calls);
        return qId;
    }

    // ─────────────────── 질문 생성 (Gasless Batch) ───────────────────

    function test_CreateQuestion_GaslessBatch() public {
        bytes32 qId = _createQuestionThroughBatch();

        QnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.asker, asker);
        assertEq(q.token, address(token));
        assertEq(q.contentHash, questionHash);
        assertEq(q.rewardAmount, reward);
        assertFalse(q.isResolved);
        assertEq(q.answerCount, 0);

        assertEq(token.balanceOf(address(escrow)), reward);
        assertEq(token.balanceOf(asker), 10000 ether - reward);
    }

    // ─────────────────── 기능 테스트 (Native 호출) ───────────────────

    function _createQuestionNative() internal returns (bytes32) {
        bytes32 qId = keccak256(abi.encodePacked("question", qNonce++));
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        escrow.createQuestion(qId, address(token), questionHash, reward);
        vm.stopPrank();
        return qId;
    }

    function test_Fail_CreateQuestion_BadHashOrReward() public {
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);

        bytes32 qId = keccak256(abi.encodePacked("question", qNonce++));
        vm.expectRevert(QnAEscrow.InvalidContentHash.selector);
        escrow.createQuestion(qId, address(token), bytes32(0), reward);

        vm.expectRevert(QnAEscrow.InvalidRewardAmount.selector);
        escrow.createQuestion(qId, address(token), questionHash, 0);

        vm.stopPrank();
    }

    // ─────────────────── 답변 등록 ───────────────────

    function test_SubmitAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        QnAEscrow.Answer memory a = escrow.getAnswer(qId, aId);
        assertEq(a.responder, responder);
        assertEq(a.contentHash, answerHash);

        QnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.answerCount, 1);
        assertEq(q.firstAnswerId, aId);
        assertEq(q.firstAnswerTs, block.timestamp);
    }

    function test_Fail_SelfAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(asker);
        vm.expectRevert(QnAEscrow.CannotAnswerOwnQuestion.selector);
        escrow.submitAnswer(qId, aId, answerHash);
    }

    function test_Fail_AnswerResolvedQuestion() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        bytes32 aId2 = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        vm.expectRevert(QnAEscrow.QuestionAlreadyResolved.selector);
        escrow.submitAnswer(qId, aId2, keccak256("Another answer"));
    }

    // ─────────────────── 답변 채택 ───────────────────

    function test_AcceptAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        uint256 responderBalBefore = token.balanceOf(responder);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(address(escrow)), 0);

        QnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertTrue(q.isResolved);
    }

    function test_Fail_AcceptByNonAsker() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(stranger);
        vm.expectRevert(QnAEscrow.OnlyAskerCanAccept.selector);
        escrow.acceptAnswer(qId, aId);
    }

    function test_Fail_DoubleAccept() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.QuestionAlreadyResolved.selector);
        escrow.acceptAnswer(qId, aId);
    }

    // ─────────────────── 질문 취소 ───────────────────

    function test_CancelQuestion() public {
        bytes32 qId = _createQuestionNative();

        vm.prank(asker);
        escrow.cancelQuestion(qId);

        assertEq(token.balanceOf(asker), 10000 ether); // Full refund
        assertEq(token.balanceOf(address(escrow)), 0);

        QnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertTrue(q.isResolved);
    }

    function test_Fail_CancelWithAnswers() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.CannotCancelWithAnswers.selector);
        escrow.cancelQuestion(qId);
    }

    function test_Fail_CancelByNonAsker() public {
        bytes32 qId = _createQuestionNative();

        vm.prank(stranger);
        vm.expectRevert(QnAEscrow.OnlyAskerCanAccept.selector);
        escrow.cancelQuestion(qId);
    }

    // ─────────────────── V2 Upgrade Features ───────────────────

    function test_Fail_UnsupportedToken() public {
        MockToken badToken = new MockToken();
        vm.prank(asker);
        badToken.mint(asker, 100 ether);

        bytes32 qId = keccak256(abi.encodePacked("question", qNonce++));
        vm.startPrank(asker);
        badToken.approve(address(escrow), type(uint256).max);

        vm.expectRevert(QnAEscrow.UnsupportedToken.selector);
        escrow.createQuestion(qId, address(badToken), questionHash, reward);
        vm.stopPrank();
    }

    function test_Fail_QuestionAlreadyExists() public {
        bytes32 qId = _createQuestionNative();
        vm.prank(asker);
        vm.expectRevert(QnAEscrow.QuestionAlreadyExists.selector);
        escrow.createQuestion(qId, address(token), questionHash, reward);
    }

    function test_BatchAdminSettle() public {
        bytes32 qId1 = _createQuestionNative();
        bytes32 qId2 = _createQuestionNative();

        bytes32 aId1 = keccak256(abi.encodePacked("a", aNonce++));
        bytes32 aId2 = keccak256(abi.encodePacked("a", aNonce++));

        vm.prank(responder);
        escrow.submitAnswer(qId1, aId1, answerHash);

        vm.prank(stranger);
        escrow.submitAnswer(qId2, aId2, answerHash);

        bytes32[] memory qIds = new bytes32[](2);
        qIds[0] = qId1;
        qIds[1] = qId2;

        bytes32[] memory aIds = new bytes32[](2);
        aIds[0] = aId1;
        aIds[1] = aId2;

        uint256 responderBalBefore = token.balanceOf(responder);
        uint256 strangerBalBefore = token.balanceOf(stranger);

        vm.prank(owner);
        escrow.batchAdminSettle(qIds, aIds);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(stranger), strangerBalBefore + reward);

        assertTrue(escrow.getQuestion(qId1).isResolved);
        assertTrue(escrow.getQuestion(qId2).isResolved);
    }

    function test_BatchAdminRefund() public {
        bytes32 qId1 = _createQuestionNative();
        bytes32 qId2 = _createQuestionNative();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = qId1;
        ids[1] = qId2;

        vm.prank(owner);
        escrow.batchAdminRefund(ids);

        assertEq(token.balanceOf(asker), 10_000 ether);

        assertTrue(escrow.getQuestion(qId1).isResolved);
        assertTrue(escrow.getQuestion(qId2).isResolved);
    }

    function test_RelayerFunctions() public {
        vm.prank(owner);
        escrow.updateRelayer(relayer, true);

        bytes32 qId1 = _createQuestionNative();
        bytes32 qId2 = _createQuestionNative();

        bytes32 aId1 = keccak256(abi.encodePacked("a", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId1, aId1, answerHash);

        // Relayer can execute settle and refund
        vm.prank(relayer);
        escrow.adminSettle(qId1, aId1);

        vm.prank(relayer);
        escrow.adminRefund(qId2);

        assertTrue(escrow.getQuestion(qId1).isResolved);
        assertTrue(escrow.getQuestion(qId2).isResolved);
    }

    function test_AutoAcceptFirstAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        // Fast forward 7 days + 1 second
        vm.warp(block.timestamp + 7 days + 1);

        uint256 responderBalBefore = token.balanceOf(responder);

        vm.prank(owner);
        escrow.autoAcceptFirstAnswer(qId);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(address(escrow)), 0);

        QnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertTrue(q.isResolved);
    }

    function test_BatchAutoAcceptFirstAnswer() public {
        bytes32 qId1 = _createQuestionNative();
        bytes32 qId2 = _createQuestionNative();

        bytes32 aId1 = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId1, aId1, answerHash);

        bytes32 aId2 = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(stranger);
        escrow.submitAnswer(qId2, aId2, answerHash);

        // Fast forward 7 days + 1 second
        vm.warp(block.timestamp + 7 days + 1);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = qId1;
        ids[1] = qId2;

        uint256 responderBalBefore = token.balanceOf(responder);
        uint256 strangerBalBefore = token.balanceOf(stranger);

        vm.prank(owner);
        escrow.batchAutoAcceptFirstAnswer(ids);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(stranger), strangerBalBefore + reward);

        assertTrue(escrow.getQuestion(qId1).isResolved);
        assertTrue(escrow.getQuestion(qId2).isResolved);
    }

    function test_Fail_AutoAcceptFirstAnswer_TooEarly() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        // Fast forward less than 7 days
        vm.warp(block.timestamp + 6 days);

        vm.prank(owner);
        vm.expectRevert(QnAEscrow.CannotAutoAcceptYet.selector);
        escrow.autoAcceptFirstAnswer(qId);
    }

    function test_Fail_AutoAcceptFirstAnswer_NoAnswers() public {
        bytes32 qId = _createQuestionNative();

        vm.warp(block.timestamp + 8 days);

        vm.prank(owner);
        vm.expectRevert(QnAEscrow.NoAnswersToAutoAccept.selector);
        escrow.autoAcceptFirstAnswer(qId);
    }
}
