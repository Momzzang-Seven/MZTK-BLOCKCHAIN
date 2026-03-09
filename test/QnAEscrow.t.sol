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
    address public relayer = address(999);

    bytes32 public questionHash = keccak256("What is Solidity?");
    bytes32 public answerHash = keccak256("Solidity is a smart contract language.");
    uint256 public reward = 100 ether;

    // EIP-7702 Batch Account Simulation
    BatchImplementation public batchImpl;

    function setUp() public {
        asker = vm.addr(askerPk);

        token = new MockToken();
        escrow = new QnAEscrow();
        batchImpl = new BatchImplementation();

        token.mint(asker, 10000 ether);
        
        vm.etch(asker, address(batchImpl).code);
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
        bytes32 structHash = keccak256(abi.encode(BATCH_TYPEHASH, currentNonce, keccak256(abi.encodePacked(callHashes))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(askerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        BatchImplementation(payable(asker)).execute(calls, signature);
    }

    function _createQuestionThroughBatch() internal returns (uint256 qId) {
        qId = escrow.questionCount();
        
        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](2);
        
        calls[0] = BatchImplementation.Call({
            to: address(token),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), reward)
        });

        calls[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                QnAEscrow.createQuestion.selector,
                address(token), questionHash, reward
            )
        });

        _executeBatchAsRelayer(calls);
        return qId;
    }

    // ─────────────────── 질문 생성 (Gasless Batch) ───────────────────

    function test_CreateQuestion_GaslessBatch() public {
        uint256 qId = _createQuestionThroughBatch();

        (address a, address t, bytes32 ch, uint256 ra, bool resolved, uint256 ac) = escrow.getQuestion(qId);
        assertEq(a, asker);
        assertEq(t, address(token));
        assertEq(ch, questionHash);
        assertEq(ra, reward);
        assertFalse(resolved);
        assertEq(ac, 0);

        assertEq(token.balanceOf(address(escrow)), reward);
        assertEq(token.balanceOf(asker), 10000 ether - reward);
    }

    // ─────────────────── 기능 테스트 (Native 호출) ───────────────────

    function _createQuestionNative() internal returns (uint256) {
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        uint256 qId = escrow.createQuestion(address(token), questionHash, reward);
        vm.stopPrank();
        return qId;
    }

    function test_Fail_CreateQuestion_ZeroHash() public {
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(QnAEscrow.InvalidContentHash.selector);
        escrow.createQuestion(address(token), bytes32(0), reward);
        vm.stopPrank();
    }

    function test_Fail_CreateQuestion_ZeroReward() public {
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(QnAEscrow.InvalidRewardAmount.selector);
        escrow.createQuestion(address(token), questionHash, 0);
        vm.stopPrank();
    }

    // ─────────────────── 답변 등록 ───────────────────

    function test_SubmitAnswer() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        uint256 aId = escrow.submitAnswer(qId, answerHash);

        (address r, bytes32 ch) = escrow.getAnswer(qId, aId);
        assertEq(r, responder);
        assertEq(ch, answerHash);

        (,,,,, uint256 ac) = escrow.getQuestion(qId);
        assertEq(ac, 1);
    }

    function test_Fail_SelfAnswer() public {
        uint256 qId = _createQuestionNative();

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.CannotAnswerOwnQuestion.selector);
        escrow.submitAnswer(qId, answerHash);
    }

    function test_Fail_AnswerResolvedQuestion() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        uint256 aId = escrow.submitAnswer(qId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        vm.prank(responder);
        vm.expectRevert(QnAEscrow.QuestionAlreadyResolved.selector);
        escrow.submitAnswer(qId, keccak256("Another answer"));
    }

    // ─────────────────── 답변 채택 ───────────────────

    function test_AcceptAnswer() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        uint256 aId = escrow.submitAnswer(qId, answerHash);

        uint256 responderBalBefore = token.balanceOf(responder);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        assertEq(token.balanceOf(responder), responderBalBefore + reward);
        assertEq(token.balanceOf(address(escrow)), 0);

        (,,,, bool resolved,) = escrow.getQuestion(qId);
        assertTrue(resolved);
    }

    function test_Fail_AcceptByNonAsker() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        uint256 aId = escrow.submitAnswer(qId, answerHash);

        vm.prank(stranger);
        vm.expectRevert(QnAEscrow.OnlyAskerCanAccept.selector);
        escrow.acceptAnswer(qId, aId);
    }

    function test_Fail_DoubleAccept() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        uint256 aId = escrow.submitAnswer(qId, answerHash);

        vm.prank(asker);
        escrow.acceptAnswer(qId, aId);

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.QuestionAlreadyResolved.selector);
        escrow.acceptAnswer(qId, aId);
    }

    // ─────────────────── 질문 취소 ───────────────────

    function test_CancelQuestion() public {
        uint256 qId = _createQuestionNative();

        vm.prank(asker);
        escrow.cancelQuestion(qId);

        assertEq(token.balanceOf(asker), 10000 ether); // Full refund
        assertEq(token.balanceOf(address(escrow)), 0);

        (,,,, bool resolved,) = escrow.getQuestion(qId);
        assertTrue(resolved);
    }

    function test_Fail_CancelWithAnswers() public {
        uint256 qId = _createQuestionNative();

        vm.prank(responder);
        escrow.submitAnswer(qId, answerHash);

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.CannotCancelWithAnswers.selector);
        escrow.cancelQuestion(qId);
    }

    function test_Fail_CancelByNonAsker() public {
        uint256 qId = _createQuestionNative();

        vm.prank(stranger);
        vm.expectRevert(QnAEscrow.OnlyAskerCanAccept.selector);
        escrow.cancelQuestion(qId);
    }

    function test_Fail_CancelResolvedQuestion() public {
        uint256 qId = _createQuestionNative();

        vm.prank(asker);
        escrow.cancelQuestion(qId);

        vm.prank(asker);
        vm.expectRevert(QnAEscrow.QuestionAlreadyResolved.selector);
        escrow.cancelQuestion(qId);
    }
}
