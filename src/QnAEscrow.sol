// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MztkEscrowBase} from "./MztkEscrowBase.sol";
import {IQnAEscrow} from "./interfaces/IQnAEscrow.sol";

contract QnAEscrow is IQnAEscrow, MztkEscrowBase {
    using SafeERC20 for IERC20;

    // ─── EIP-712 typehashes ────────────────────────────────────────────────────

    bytes32 private constant _CREATE_QUESTION_TYPEHASH = keccak256(
        "CreateQuestion(address creator,bytes32 questionId,address token,uint256 rewardAmount,bytes32 questionHash,uint256 signedAt)"
    );
    bytes32 private constant _UPDATE_QUESTION_TYPEHASH =
        keccak256("UpdateQuestion(address asker,bytes32 questionId,bytes32 newQuestionHash,uint256 signedAt)");
    bytes32 private constant _SUBMIT_ANSWER_TYPEHASH = keccak256(
        "SubmitAnswer(address responder,bytes32 questionId,bytes32 answerId,bytes32 contentHash,uint256 signedAt)"
    );
    bytes32 private constant _UPDATE_ANSWER_TYPEHASH = keccak256(
        "UpdateAnswer(address responder,bytes32 questionId,bytes32 answerId,bytes32 newContentHash,uint256 signedAt)"
    );
    bytes32 private constant _DELETE_ANSWER_TYPEHASH =
        keccak256("DeleteAnswer(address responder,bytes32 questionId,bytes32 answerId,uint256 signedAt)");
    bytes32 private constant _ACCEPT_ANSWER_TYPEHASH = keccak256(
        "AcceptAnswer(address asker,bytes32 questionId,bytes32 answerId,bytes32 questionHash,bytes32 contentHash,uint256 signedAt)"
    );
    bytes32 private constant _DELETE_QUESTION_TYPEHASH =
        keccak256("DeleteQuestion(address asker,bytes32 questionId,uint256 signedAt)");

    // ─── State constants ───────────────────────────────────────────────────────

    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_ANSWERED = 1100;
    uint16 public constant STATE_PAID_OUT = 2100;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_DELETED = 5000;
    uint16 public constant STATE_DELETED_WITH_ANSWERS = 5100;
    uint16 public constant STATE_DEADLINE_REFUNDED = 6000;

    // ─── Storage ───────────────────────────────────────────────────────────────

    /// @notice All questions, keyed by questionId.
    mapping(bytes32 => Question) public questions;
    /// @notice All answers, keyed by (questionId, answerId).
    mapping(bytes32 => mapping(bytes32 => Answer)) public answers;

    // ─── Constructor ───────────────────────────────────────────────────────────

    constructor(address initialOwner, address initialSigner)
        MztkEscrowBase(initialOwner, initialSigner, "QnAEscrow", "1")
    {}

    // ─── User actions: questions ───────────────────────────────────────────────

    /// @inheritdoc IQnAEscrow
    function createQuestion(
        bytes32 questionId,
        address token,
        uint256 rewardAmount,
        bytes32 questionHash,
        uint256 signedAt,
        bytes calldata signature
    ) external override {
        if (token == address(0)) revert InvalidAddress();
        if (questionId == bytes32(0)) revert InvalidId();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (rewardAmount == 0) revert InvalidRewardAmount();
        if (questions[questionId].asker != address(0)) revert QuestionAlreadyExists();
        if (questionHash == bytes32(0)) revert InvalidContentHash();

        bytes32 structHash = keccak256(
            abi.encode(_CREATE_QUESTION_TYPEHASH, msg.sender, questionId, token, rewardAmount, questionHash, signedAt)
        );
        _verifyServerSig(structHash, signedAt, signature);

        uint48 deadline = uint48(block.timestamp) + defaultDeadlineDuration;

        questions[questionId] = Question({
            questionId: questionId,
            rewardAmount: rewardAmount,
            acceptedAnswerId: bytes32(0),
            questionHash: questionHash,
            token: token,
            asker: msg.sender,
            deadline: deadline,
            answerCount: 0,
            state: STATE_CREATED
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit QuestionCreated(questionId, msg.sender, token, rewardAmount);
    }

    /// @inheritdoc IQnAEscrow
    function updateQuestion(bytes32 questionId, bytes32 newQuestionHash, uint256 signedAt, bytes calldata signature)
        external
        override
    {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAsker();
        if (newQuestionHash == bytes32(0)) revert InvalidContentHash();

        bytes32 structHash =
            keccak256(abi.encode(_UPDATE_QUESTION_TYPEHASH, msg.sender, questionId, newQuestionHash, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        q.questionHash = newQuestionHash;
        emit QuestionUpdated(questionId, msg.sender, newQuestionHash);
    }

    /// @inheritdoc IQnAEscrow
    function deleteQuestion(bytes32 questionId, uint256 signedAt, bytes calldata signature) external override {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        // Only valid when no answers exist; STATE_CREATED implies answerCount == 0 (invariant).
        if (q.state != STATE_CREATED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAsker();

        bytes32 structHash = keccak256(abi.encode(_DELETE_QUESTION_TYPEHASH, msg.sender, questionId, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        q.state = STATE_DELETED;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit QuestionDeleted(questionId);
    }

    // ─── User actions: answers ─────────────────────────────────────────────────

    /// @inheritdoc IQnAEscrow
    function submitAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 contentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external override {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        // Prevent griefing: submitting an answer after deadline changes claimExpiredRefund
        // from permissionless to asker-only, forcing manual intervention on an expired question.
        if (block.timestamp > q.deadline) revert DeadlineExpired();
        if (answerId == bytes32(0)) revert InvalidId();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (msg.sender == q.asker) revert CannotAnswerOwnQuestion();
        if (answers[questionId][answerId].responder != address(0)) revert AnswerAlreadyExists();

        bytes32 structHash =
            keccak256(abi.encode(_SUBMIT_ANSWER_TYPEHASH, msg.sender, questionId, answerId, contentHash, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        if (q.state == STATE_CREATED) {
            q.state = STATE_ANSWERED;
        }

        q.answerCount += 1;
        answers[questionId][answerId] = Answer({answerId: answerId, contentHash: contentHash, responder: msg.sender});

        emit AnswerSubmitted(questionId, answerId, msg.sender, contentHash);
    }

    /// @inheritdoc IQnAEscrow
    function updateAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 newContentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external override {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        // Block updates after deadline: content changes on an expired question are meaningless.
        if (block.timestamp > q.deadline) revert DeadlineExpired();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (msg.sender != a.responder) revert OnlyResponderCanUpdate();
        if (newContentHash == bytes32(0)) revert InvalidContentHash();

        bytes32 structHash =
            keccak256(abi.encode(_UPDATE_ANSWER_TYPEHASH, msg.sender, questionId, answerId, newContentHash, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        a.contentHash = newContentHash;
        emit AnswerUpdated(questionId, answerId, msg.sender, newContentHash);
    }

    /// @inheritdoc IQnAEscrow
    function deleteAnswer(bytes32 questionId, bytes32 answerId, uint256 signedAt, bytes calldata signature)
        external
        override
    {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (msg.sender != a.responder) revert OnlyResponderCanDelete();

        bytes32 structHash = keccak256(abi.encode(_DELETE_ANSWER_TYPEHASH, msg.sender, questionId, answerId, signedAt));
        _verifyServerSig(structHash, signedAt, signature);

        address responder = a.responder;
        delete answers[questionId][answerId];

        q.answerCount -= 1;
        if (q.answerCount == 0) {
            q.state = STATE_CREATED;
        }

        emit AnswerDeleted(questionId, answerId, responder);
    }

    /// @inheritdoc IQnAEscrow
    function acceptAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 questionHash,
        bytes32 contentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external override {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.questionHash != questionHash) revert HashMismatch();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (a.contentHash != contentHash) revert HashMismatch();

        bytes32 structHash = keccak256(
            abi.encode(_ACCEPT_ANSWER_TYPEHASH, msg.sender, questionId, answerId, questionHash, contentHash, signedAt)
        );
        _verifyServerSig(structHash, signedAt, signature);

        q.state = STATE_PAID_OUT;
        q.acceptedAnswerId = answerId;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AnswerAccepted(questionId, answerId, a.responder, q.rewardAmount, questionHash, contentHash);
    }

    // ─── Relayer / admin actions ───────────────────────────────────────────────

    /// @inheritdoc IQnAEscrow
    function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash)
        external
        override
        onlyRelayerOrOwner
    {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        // Prevent admin settlement after escrow deadline so claimExpiredRefund remains valid.
        if (block.timestamp > q.deadline) revert DeadlineExpired();
        if (q.questionHash != questionHash) revert HashMismatch();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (a.contentHash != contentHash) revert HashMismatch();

        q.state = STATE_ADMIN_SETTLED;
        q.acceptedAnswerId = answerId;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AdminSettled(questionId, answerId, a.responder, q.rewardAmount, questionHash, contentHash);
    }

    /// @inheritdoc IQnAEscrow
    function adminRefund(bytes32 questionId) external override onlyRelayerOrOwner {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();

        // Intentionally no deadline guard — refunding is always safe.
        // After deadline, both adminRefund and claimExpiredRefund are callable; first caller wins.
        q.state = (q.answerCount > 0) ? STATE_DELETED_WITH_ANSWERS : STATE_DELETED;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit AdminRefunded(questionId, q.asker, q.rewardAmount);
    }

    // ─── Permissionless ───────────────────────────────────────────────────────

    /// @inheritdoc IQnAEscrow
    /// @dev Safety invariant against MEV front-running:
    ///        • STATE_CREATED (no answers): permissionless — anyone can trigger the refund.
    ///        • STATE_ANSWERED (has answers): only the asker may call, because acceptAnswer
    ///          is still available to them. A third party must not be able to steal the
    ///          asker's chance to pay a responder by front-running this function.
    function claimExpiredRefund(bytes32 questionId) external override {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (block.timestamp <= q.deadline) revert DeadlineNotExpired();
        if (q.answerCount > 0 && msg.sender != q.asker) revert OnlyAsker();

        q.state = STATE_DEADLINE_REFUNDED;
        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit DeadlineRefunded(questionId, q.asker, q.rewardAmount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IQnAEscrow
    function getQuestion(bytes32 questionId) external view override returns (Question memory) {
        return questions[questionId];
    }

    /// @inheritdoc IQnAEscrow
    function getQuestions(bytes32[] calldata questionIds) external view override returns (Question[] memory) {
        Question[] memory result = new Question[](questionIds.length);
        for (uint256 i = 0; i < questionIds.length; i++) {
            result[i] = questions[questionIds[i]];
        }
        return result;
    }

    /// @inheritdoc IQnAEscrow
    function getAnswer(bytes32 questionId, bytes32 answerId) external view override returns (Answer memory) {
        return answers[questionId][answerId];
    }

    /// @inheritdoc IQnAEscrow
    function getAnswers(bytes32 questionId, bytes32[] calldata answerIds)
        external
        view
        override
        returns (Answer[] memory)
    {
        Answer[] memory result = new Answer[](answerIds.length);
        for (uint256 i = 0; i < answerIds.length; i++) {
            result[i] = answers[questionId][answerIds[i]];
        }
        return result;
    }
}
