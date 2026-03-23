// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";
import {IQnAEscrow} from "../src/interfaces/IQnAEscrow.sol";

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
    bytes32 public acceptedHash = keccak256("Accepted Answer Hash");
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

        // createQuestion no longer takes contentHash
        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(QnAEscrow.createQuestion.selector, qId, address(token), reward)
        });

        _executeBatchAsRelayer(calls);
        return qId;
    }

    // ─────────────────── 질문 생성 (Gasless Batch) ───────────────────

    function test_CreateQuestion_GaslessBatch() public {
        bytes32 qId = _createQuestionThroughBatch();

        IQnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.questionId, qId);
        assertEq(q.asker, asker);
        assertEq(q.token, address(token));
        assertEq(q.contentHash, bytes32(0));
        assertEq(q.rewardAmount, reward);
        assertEq(q.state, escrow.STATE_CREATED());
        assertEq(q.answerCount, 0);

        assertEq(token.balanceOf(address(escrow)), reward);
        assertEq(token.balanceOf(asker), 10000 ether - reward);
    }

    // ─────────────────── 기능 테스트 (Native 호출) ───────────────────

    function _createQuestionNative() internal returns (bytes32) {
        bytes32 qId = keccak256(abi.encodePacked("question", qNonce++));
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        escrow.createQuestion(qId, address(token), reward);
        vm.stopPrank();
        return qId;
    }

    function test_Fail_CreateQuestion_BadReward() public {
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);

        bytes32 qId = keccak256(abi.encodePacked("question", qNonce++));

        vm.expectRevert(IQnAEscrow.InvalidRewardAmount.selector);
        escrow.createQuestion(qId, address(token), 0);

        vm.stopPrank();
    }

    // ─────────────────── 답변 등록 ───────────────────

    function test_SubmitAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        IQnAEscrow.Answer memory a = escrow.getAnswer(qId, aId);
        assertEq(a.answerId, aId);
        assertEq(a.responder, responder);
        assertEq(a.contentHash, answerHash);

        IQnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.answerCount, 1);
        assertEq(q.state, escrow.STATE_ANSWERED());
    }

    function test_Fail_SelfAnswer() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.CannotAnswerOwnQuestion.selector);
        escrow.submitAnswer(qId, aId, answerHash);
    }

    function test_Fail_AnswerResolvedQuestion() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId, acceptedHash);

        bytes32 aId2 = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.QuestionAlreadyResolved.selector);
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
        escrow.acceptAnswer(qId, aId, acceptedHash);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(address(escrow)), 0);

        IQnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.state, escrow.STATE_PAID_OUT());
        assertEq(q.contentHash, acceptedHash);
    }

    function test_Fail_AcceptByNonAsker() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyAskerCanAccept.selector);
        escrow.acceptAnswer(qId, aId, acceptedHash);
    }

    function test_Fail_DoubleAccept() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId, acceptedHash);

        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.QuestionAlreadyResolved.selector);
        escrow.acceptAnswer(qId, aId, acceptedHash);
    }

    // ─────────────────── 질문 취소 ───────────────────

    function test_CancelQuestion() public {
        bytes32 qId = _createQuestionNative();

        vm.prank(asker);
        escrow.cancelQuestion(qId);

        assertEq(token.balanceOf(asker), 10000 ether); // Full refund
        assertEq(token.balanceOf(address(escrow)), 0);

        IQnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.state, escrow.STATE_DELETED());
    }

    function test_Fail_CancelWithAnswers() public {
        bytes32 qId = _createQuestionNative();

        bytes32 aId = keccak256(abi.encodePacked("answer", aNonce++));
        vm.prank(responder);
        escrow.submitAnswer(qId, aId, answerHash);

        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.CannotCancelWithAnswers.selector);
        escrow.cancelQuestion(qId);
    }

    function test_Fail_CancelByNonAsker() public {
        bytes32 qId = _createQuestionNative();

        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyAskerCanAccept.selector);
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

        vm.expectRevert(IQnAEscrow.UnsupportedToken.selector);
        escrow.createQuestion(qId, address(badToken), reward);
        vm.stopPrank();
    }

    function test_Fail_QuestionAlreadyExists() public {
        bytes32 qId = _createQuestionNative();
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.QuestionAlreadyExists.selector);
        escrow.createQuestion(qId, address(token), reward);
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
        escrow.adminSettle(qId1, aId1, acceptedHash);

        vm.prank(relayer);
        escrow.adminRefund(qId2);

        assertEq(escrow.getQuestion(qId1).state, escrow.STATE_ADMIN_SETTLED());
        assertEq(escrow.getQuestion(qId1).contentHash, acceptedHash);
        assertEq(escrow.getQuestion(qId2).state, escrow.STATE_DELETED());
    }

    function test_GetQuestions() public {
        bytes32 qId1 = _createQuestionNative();
        bytes32 qId2 = _createQuestionNative();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = qId1;
        ids[1] = qId2;

        IQnAEscrow.Question[] memory qs = escrow.getQuestions(ids);
        assertEq(qs.length, 2);
        assertEq(qs[0].questionId, qId1);
        assertEq(qs[1].questionId, qId2);
        assertEq(qs[0].state, escrow.STATE_CREATED());
        assertEq(qs[1].state, escrow.STATE_CREATED());
    }
}
