// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {QnAEscrow} from "../src/QnAEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    uint256 public signerPk = 0x5EF1;
    address public signerAddr;
    address public responder = address(2);
    address public stranger = address(3);
    address public owner = address(5);
    address public relayer = address(999);
    bytes32 public qHash = keccak256("What is Solidity?");
    bytes32 public aHash = keccak256("Solidity is a smart contract language.");
    uint256 public reward = 100 ether;
    uint256 public qN = 1;
    uint256 public aN = 1;
    bytes32 private constant _TYPEHASH = keccak256(
        "CreateQuestion(address creator,bytes32 questionId,address token,uint256 rewardAmount,bytes32 questionHash,uint256 signedAt)"
    );
    bytes32 private constant _UPDATE_Q_TYPEHASH = keccak256(
        "UpdateQuestion(address asker,bytes32 questionId,bytes32 newQuestionHash,uint256 signedAt)"
    );
    bytes32 private constant _SUBMIT_A_TYPEHASH = keccak256(
        "SubmitAnswer(address responder,bytes32 questionId,bytes32 answerId,bytes32 contentHash,uint256 signedAt)"
    );
    bytes32 private constant _UPDATE_A_TYPEHASH = keccak256(
        "UpdateAnswer(address responder,bytes32 questionId,bytes32 answerId,bytes32 newContentHash,uint256 signedAt)"
    );
    BatchImplementation public batchImpl;

    function setUp() public {
        asker = vm.addr(askerPk);
        signerAddr = vm.addr(signerPk);
        token = new MockToken();
        escrow = new QnAEscrow(owner, signerAddr);
        batchImpl = new BatchImplementation();
        token.mint(asker, 10000 ether);
        vm.etch(asker, address(batchImpl).code);
        vm.prank(owner);
        escrow.updateTokenSupport(address(token), true);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("QnAEscrow")),
                keccak256(bytes("1")),
                block.chainid,
                address(escrow)
            )
        );
    }

    function _sign(
        uint256 pk,
        address creator,
        bytes32 qId,
        address tok,
        uint256 amt,
        bytes32 qh,
        uint256 sat
    ) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(_TYPEHASH, creator, qId, tok, amt, qh, sat));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signUpdateQ(uint256 pk, address askerAddr, bytes32 qId, bytes32 newQh, uint256 sat)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encode(_UPDATE_Q_TYPEHASH, askerAddr, qId, newQh, sat));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSubmitA(uint256 pk, address responderAddr, bytes32 qId, bytes32 aId, bytes32 cHash, uint256 sat)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encode(_SUBMIT_A_TYPEHASH, responderAddr, qId, aId, cHash, sat));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signUpdateA(uint256 pk, address responderAddr, bytes32 qId, bytes32 aId, bytes32 newCh, uint256 sat)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encode(_UPDATE_A_TYPEHASH, responderAddr, qId, aId, newCh, sat));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Helpers that submit a valid server-signed answer on behalf of a given responder
    function _submit(bytes32 qId, bytes32 aId, bytes32 cHash, address responderAddr) internal {
        uint256 sat = block.timestamp;
        bytes memory sig = _signSubmitA(signerPk, responderAddr, qId, aId, cHash, sat);
        vm.prank(responderAddr);
        escrow.submitAnswer(qId, aId, cHash, sat, sig);
    }

    function _execBatch(BatchImplementation.Call[] memory calls) internal {
        bytes32 dom = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BatchAccount")),
                keccak256(bytes("1")),
                block.chainid,
                asker
            )
        );
        bytes32 ct = keccak256("Call(address to,uint256 value,bytes data)");
        bytes32 bt = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");
        bytes32[] memory ch = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            ch[i] = keccak256(abi.encode(ct, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }
        uint256 cn = BatchImplementation(payable(asker)).txNonce();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(bt, cn, keccak256(abi.encodePacked(ch)))))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(askerPk, digest);
        vm.prank(relayer);
        BatchImplementation(payable(asker)).execute(calls, abi.encodePacked(r, s, v));
    }

    function _ask() internal returns (bytes32) {
        bytes32 qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(token), reward, qHash, sat);
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        escrow.createQuestion(qId, address(token), reward, qHash, sat, sig);
        vm.stopPrank();
        return qId;
    }

    function _askBatch() internal returns (bytes32 qId) {
        qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(token), reward, qHash, sat);
        BatchImplementation.Call[] memory c = new BatchImplementation.Call[](2);
        c[0] = BatchImplementation.Call({
            to: address(token), value: 0, data: abi.encodeWithSelector(IERC20.approve.selector, address(escrow), reward)
        });
        c[1] = BatchImplementation.Call({
            to: address(escrow),
            value: 0,
            data: abi.encodeWithSelector(
                QnAEscrow.createQuestion.selector, qId, address(token), reward, qHash, sat, sig
            )
        });
        _execBatch(c);
    }

    // ?????? Question Creation ??????

    function test_CreateQuestion_GaslessBatch() public {
        bytes32 qId = _askBatch();
        IQnAEscrow.Question memory q = escrow.getQuestion(qId);
        assertEq(q.asker, asker);
        assertEq(q.state, escrow.STATE_CREATED());
        assertEq(token.balanceOf(address(escrow)), reward);
    }

    function test_Fail_InvalidSignature() public {
        bytes32 qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory bad = _sign(0xBAD, asker, qId, address(token), reward, qHash, sat);
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.createQuestion(qId, address(token), reward, qHash, sat, bad);
        vm.stopPrank();
    }

    function test_Fail_ExpiredSig() public {
        bytes32 qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(token), reward, qHash, sat);
        vm.warp(block.timestamp + 16 minutes);
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IQnAEscrow.SignatureExpired.selector);
        escrow.createQuestion(qId, address(token), reward, qHash, sat, sig);
        vm.stopPrank();
    }

    function test_Fail_SignatureReplay() public {
        bytes32 qId1 = keccak256(abi.encodePacked("question", qN++));
        bytes32 qId2 = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId1, address(token), reward, qHash, sat);
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        escrow.createQuestion(qId1, address(token), reward, qHash, sat, sig);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.createQuestion(qId2, address(token), reward, qHash, sat, sig);
        vm.stopPrank();
    }

    function test_Fail_BadReward() public {
        bytes32 qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(token), 0, qHash, sat);
        vm.startPrank(asker);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IQnAEscrow.InvalidRewardAmount.selector);
        escrow.createQuestion(qId, address(token), 0, qHash, sat, sig);
        vm.stopPrank();
    }

    // ?????? Answer Flow ??????

    function test_SubmitAnswer() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_ANSWERED());
    }

    function test_Fail_SelfAnswer() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _signSubmitA(signerPk, asker, qId, aId, aHash, sat);
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.CannotAnswerOwnQuestion.selector);
        escrow.submitAnswer(qId, aId, aHash, sat, sig);
    }

    function test_AcceptAnswer() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        uint256 bal = token.balanceOf(responder);
        vm.prank(asker);
        escrow.acceptAnswer(qId, aId, qHash, aHash);
        assertEq(token.balanceOf(responder), bal + reward);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_PAID_OUT());
    }

    function test_Fail_AcceptByNonAsker() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyAskerCanAccept.selector);
        escrow.acceptAnswer(qId, aId, qHash, aHash);
    }

    function test_DeleteAnswer_LastAnswer_ResetState() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_ANSWERED());
        vm.prank(responder);
        escrow.deleteAnswer(qId, aId);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_CREATED());
    }

    function test_deleteQuestion() public {
        bytes32 qId = _ask();
        vm.prank(asker);
        escrow.deleteQuestion(qId);
        assertEq(token.balanceOf(asker), 10000 ether);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_DELETED());
    }

    function test_Fail_DeleteWithAnswers() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        // State is now STATE_ANSWERED; deleteQuestion checks STATE_CREATED only
        // so it reverts with QuestionAlreadyResolved before reaching CannotDeleteWithAnswers
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.QuestionAlreadyResolved.selector);
        escrow.deleteQuestion(qId);
    }

    // ?????? Admin ??????

    function test_RelayerFunctions() public {
        vm.prank(owner);
        escrow.updateRelayer(relayer, true);
        bytes32 qId1 = _ask();
        bytes32 qId2 = _ask();
        bytes32 aId = keccak256(abi.encodePacked("a", aN++));
        _submit(qId1, aId, aHash, responder);
        vm.prank(relayer);
        escrow.adminSettle(qId1, aId, qHash, aHash);
        vm.prank(relayer);
        escrow.adminRefund(qId2);
        assertEq(escrow.getQuestion(qId1).state, escrow.STATE_ADMIN_SETTLED());
        assertEq(escrow.getQuestion(qId2).state, escrow.STATE_DELETED());
    }

    // ?????? Deadline / Emergency Exit ??????

    function test_ClaimExpiredRefund_NoAnswers() public {
        bytes32 qId = _ask();
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(asker);
        escrow.claimExpiredRefund(qId);
        assertEq(token.balanceOf(asker), bal + reward);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_DEADLINE_REFUNDED());
    }

    function test_ClaimExpiredRefund_WithAnswers() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(asker);
        // answers exist: only asker can forfeit (MEV guard)
        vm.prank(asker);
        escrow.claimExpiredRefund(qId);
        assertEq(token.balanceOf(asker), bal + reward);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_DEADLINE_REFUNDED());
    }

    function test_ClaimExpiredRefund_ByAnyone() public {
        // No answers: anyone may trigger the refund
        bytes32 qId = _ask();
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(asker);
        vm.prank(stranger);
        escrow.claimExpiredRefund(qId);
        assertEq(token.balanceOf(asker), bal + reward);
    }

    function test_Fail_ClaimExpiredRefund_StrangerWithAnswers() public {
        // Has answers: third party must NOT be able to frontrun asker's acceptAnswer
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        vm.warp(block.timestamp + 31 days);
        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyAsker.selector);
        escrow.claimExpiredRefund(qId);
    }

    function test_ClaimExpiredRefund_AskerWithAnswers() public {
        // Has answers: asker can consciously choose to forfeit
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        vm.warp(block.timestamp + 31 days);
        uint256 bal = token.balanceOf(asker);
        vm.prank(asker);
        escrow.claimExpiredRefund(qId);
        assertEq(token.balanceOf(asker), bal + reward);
        assertEq(escrow.getQuestion(qId).state, escrow.STATE_DEADLINE_REFUNDED());
    }

    function test_Fail_ClaimTooEarly() public {
        bytes32 qId = _ask();
        vm.expectRevert(IQnAEscrow.DeadlineNotExpired.selector);
        escrow.claimExpiredRefund(qId);
    }

    function test_Fail_AdminSettleAfterDeadline() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        vm.expectRevert(IQnAEscrow.DeadlineExpired.selector);
        escrow.adminSettle(qId, aId, qHash, aHash);
    }

    // ?????? Misc ??????

    function test_GetAnswers() public {
        bytes32 qId = _ask();
        bytes32 aId1 = keccak256(abi.encodePacked("answer", aN++));
        bytes32 aId2 = keccak256(abi.encodePacked("answer", aN++));
        bytes32 otherHash = keccak256("Another");
        _submit(qId, aId1, aHash, responder);
        _submit(qId, aId2, otherHash, stranger);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = aId1;
        ids[1] = aId2;
        IQnAEscrow.Answer[] memory r = escrow.getAnswers(qId, ids);
        assertEq(r[0].responder, responder);
        assertEq(r[1].responder, stranger);
    }

    function test_Fail_UnsupportedToken() public {
        MockToken bad = new MockToken();
        bad.mint(asker, 100 ether);
        bytes32 qId = keccak256(abi.encodePacked("question", qN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(bad), reward, qHash, sat);
        vm.startPrank(asker);
        bad.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IQnAEscrow.UnsupportedToken.selector);
        escrow.createQuestion(qId, address(bad), reward, qHash, sat, sig);
        vm.stopPrank();
    }

    function test_Fail_QuestionAlreadyExists() public {
        bytes32 qId = _ask();
        uint256 sat = block.timestamp;
        bytes memory sig = _sign(signerPk, asker, qId, address(token), reward, qHash, sat);
        vm.startPrank(asker);
        vm.expectRevert(IQnAEscrow.QuestionAlreadyExists.selector);
        escrow.createQuestion(qId, address(token), reward, qHash, sat, sig);
        vm.stopPrank();
    }

    function test_GetQuestions() public {
        bytes32 qId1 = _ask();
        bytes32 qId2 = _ask();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = qId1;
        ids[1] = qId2;
        IQnAEscrow.Question[] memory qs = escrow.getQuestions(ids);
        assertEq(qs[0].questionId, qId1);
        assertEq(qs[1].questionId, qId2);
    }

    // ─── updateQuestion: server signature ───

    function test_UpdateQuestion_Ok() public {
        bytes32 qId = _ask();
        bytes32 newQh = keccak256("revised question");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateQ(signerPk, asker, qId, newQh, sat);
        vm.prank(asker);
        escrow.updateQuestion(qId, newQh, sat, sig);
        assertEq(escrow.getQuestion(qId).questionHash, newQh);
    }

    function test_Fail_UpdateQuestion_ExpiredSig() public {
        bytes32 qId = _ask();
        bytes32 newQh = keccak256("revised question");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateQ(signerPk, asker, qId, newQh, sat);
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.SignatureExpired.selector);
        escrow.updateQuestion(qId, newQh, sat, sig);
    }

    function test_Fail_UpdateQuestion_FutureSignedAt() public {
        bytes32 qId = _ask();
        bytes32 newQh = keccak256("revised question");
        uint256 sat = block.timestamp + 1 days;
        bytes memory sig = _signUpdateQ(signerPk, asker, qId, newQh, sat);
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateQuestion(qId, newQh, sat, sig);
    }

    function test_Fail_UpdateQuestion_WrongSigner() public {
        bytes32 qId = _ask();
        bytes32 newQh = keccak256("revised question");
        uint256 sat = block.timestamp;
        bytes memory bad = _signUpdateQ(0xBAD, asker, qId, newQh, sat);
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateQuestion(qId, newQh, sat, bad);
    }

    function test_Fail_UpdateQuestion_SenderBindingBypass() public {
        // OnlyAsker ACL fires before sig check, so stranger can't even reach the signature
        // verification with a sig bound to the real asker — the role gate catches it first.
        bytes32 qId = _ask();
        bytes32 newQh = keccak256("revised question");
        uint256 sat = block.timestamp;
        bytes memory sigForAsker = _signUpdateQ(signerPk, asker, qId, newQh, sat);
        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyAsker.selector);
        escrow.updateQuestion(qId, newQh, sat, sigForAsker);
    }

    function test_Fail_UpdateQuestion_WrongTypehashField() public {
        // Sign for newQh1 but call with newQh2 → digest mismatch → InvalidSignature
        bytes32 qId = _ask();
        bytes32 newQh1 = keccak256("revised one");
        bytes32 newQh2 = keccak256("revised two");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateQ(signerPk, asker, qId, newQh1, sat);
        vm.prank(asker);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateQuestion(qId, newQh2, sat, sig);
    }

    // ─── submitAnswer: server signature ───

    function test_SubmitAnswer_Ok() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        assertEq(escrow.getAnswer(qId, aId).responder, responder);
        assertEq(escrow.getAnswer(qId, aId).contentHash, aHash);
    }

    function test_Fail_SubmitAnswer_ExpiredSig() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _signSubmitA(signerPk, responder, qId, aId, aHash, sat);
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.SignatureExpired.selector);
        escrow.submitAnswer(qId, aId, aHash, sat, sig);
    }

    function test_Fail_SubmitAnswer_FutureSignedAt() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp + 1 days;
        bytes memory sig = _signSubmitA(signerPk, responder, qId, aId, aHash, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.submitAnswer(qId, aId, aHash, sat, sig);
    }

    function test_Fail_SubmitAnswer_WrongSigner() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp;
        bytes memory bad = _signSubmitA(0xBAD, responder, qId, aId, aHash, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.submitAnswer(qId, aId, aHash, sat, bad);
    }

    function test_Fail_SubmitAnswer_SenderBindingBypass() public {
        // Server signs for `responder`, attacker (stranger) calls — msg.sender goes into the
        // structHash, so recover != signer → InvalidSignature. This proves the signature
        // is bound to the caller's address.
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp;
        bytes memory sigForResponder = _signSubmitA(signerPk, responder, qId, aId, aHash, sat);
        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.submitAnswer(qId, aId, aHash, sat, sigForResponder);
    }

    function test_Fail_SubmitAnswer_WrongQuestionId() public {
        // Signed for qId1 but called against qId2 → digest mismatch → InvalidSignature
        bytes32 qId1 = _ask();
        bytes32 qId2 = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        uint256 sat = block.timestamp;
        bytes memory sig = _signSubmitA(signerPk, responder, qId1, aId, aHash, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.submitAnswer(qId2, aId, aHash, sat, sig);
    }

    // ─── updateAnswer: server signature ───

    function test_UpdateAnswer_Ok() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateA(signerPk, responder, qId, aId, newCh, sat);
        vm.prank(responder);
        escrow.updateAnswer(qId, aId, newCh, sat, sig);
        assertEq(escrow.getAnswer(qId, aId).contentHash, newCh);
    }

    function test_Fail_UpdateAnswer_ExpiredSig() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateA(signerPk, responder, qId, aId, newCh, sat);
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.SignatureExpired.selector);
        escrow.updateAnswer(qId, aId, newCh, sat, sig);
    }

    function test_Fail_UpdateAnswer_FutureSignedAt() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp + 1 days;
        bytes memory sig = _signUpdateA(signerPk, responder, qId, aId, newCh, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateAnswer(qId, aId, newCh, sat, sig);
    }

    function test_Fail_UpdateAnswer_WrongSigner() public {
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp;
        bytes memory bad = _signUpdateA(0xBAD, responder, qId, aId, newCh, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateAnswer(qId, aId, newCh, sat, bad);
    }

    function test_Fail_UpdateAnswer_SenderBindingBypass() public {
        // OnlyResponderCanUpdate ACL fires before sig check, so the role gate catches a
        // stranger replaying responder's sig before the signature verification runs.
        bytes32 qId = _ask();
        bytes32 aId = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId, aHash, responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp;
        bytes memory sigForResponder = _signUpdateA(signerPk, responder, qId, aId, newCh, sat);
        vm.prank(stranger);
        vm.expectRevert(IQnAEscrow.OnlyResponderCanUpdate.selector);
        escrow.updateAnswer(qId, aId, newCh, sat, sigForResponder);
    }

    function test_Fail_UpdateAnswer_WrongAnswerIdInSig() public {
        // Sign for aId1 but call for aId2 (both belong to responder) → digest mismatch
        bytes32 qId = _ask();
        bytes32 aId1 = keccak256(abi.encodePacked("answer", aN++));
        bytes32 aId2 = keccak256(abi.encodePacked("answer", aN++));
        _submit(qId, aId1, aHash, responder);
        _submit(qId, aId2, keccak256("second"), responder);
        bytes32 newCh = keccak256("revised answer");
        uint256 sat = block.timestamp;
        bytes memory sig = _signUpdateA(signerPk, responder, qId, aId1, newCh, sat);
        vm.prank(responder);
        vm.expectRevert(IQnAEscrow.InvalidSignature.selector);
        escrow.updateAnswer(qId, aId2, newCh, sat, sig);
    }
}
