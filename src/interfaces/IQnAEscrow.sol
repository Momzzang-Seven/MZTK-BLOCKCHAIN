// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IEscrowBase} from "./IEscrowBase.sol";

/// @notice Interface for the MZTK Q&A Escrow contract.
///         Common admin events, errors, and functions are inherited from IEscrowBase.
interface IQnAEscrow is IEscrowBase {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct Question {
        bytes32 questionId;
        uint256 rewardAmount;
        bytes32 acceptedAnswerId;
        bytes32 questionHash;
        address token;
        address asker;
        uint48 deadline; // Unix timestamp after which the asker may self-refund
        uint32 answerCount;
        uint16 state;
    }

    struct Answer {
        bytes32 answerId;
        bytes32 contentHash;
        address responder;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event QuestionCreated(bytes32 indexed questionId, address indexed asker, address token, uint256 rewardAmount);
    event QuestionUpdated(bytes32 indexed questionId, address indexed asker, bytes32 newQuestionHash);
    event QuestionDeleted(bytes32 indexed questionId);
    event AnswerSubmitted(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, bytes32 contentHash
    );
    event AnswerUpdated(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, bytes32 newContentHash
    );
    event AnswerDeleted(bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder);
    event AnswerAccepted(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address indexed responder,
        uint256 rewardAmount,
        bytes32 questionHash,
        bytes32 contentHash
    );
    event AdminSettled(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address indexed responder,
        uint256 rewardAmount,
        bytes32 questionHash,
        bytes32 contentHash
    );
    event AdminRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount);
    /// @dev Emitted when the asker self-refunds after the deadline has passed.
    event DeadlineRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidId();
    error InvalidContentHash();
    error InvalidRewardAmount();
    error QuestionAlreadyExists();
    error AnswerAlreadyExists();
    error QuestionNotFound();
    error QuestionAlreadyResolved();
    error OnlyAskerCanAccept();
    error OnlyAsker();
    error AnswerNotFound();
    error CannotAnswerOwnQuestion();
    error CannotDeleteWithAnswers();
    error CannotUpdateWithAnswers();
    error OnlyResponderCanDelete();
    error OnlyResponderCanUpdate();
    error HashMismatch();
    error DeadlineNotExpired();
    error DeadlineExpired();

    // ─── Functions ────────────────────────────────────────────────────────────

    /// @notice Create a question and lock `rewardAmount` tokens in escrow.
    ///         Requires a valid server-issued EIP-712 authorization.
    function createQuestion(
        bytes32 questionId,
        address token,
        uint256 rewardAmount,
        bytes32 questionHash,
        uint256 signedAt,
        bytes calldata signature
    ) external;

    /// @notice Update the content hash of an existing question (no answers yet).
    ///         Requires a valid server-issued EIP-712 authorization.
    function updateQuestion(bytes32 questionId, bytes32 newQuestionHash, uint256 signedAt, bytes calldata signature)
        external;

    /// @notice Submit an answer to a question.
    ///         Requires a valid server-issued EIP-712 authorization.
    function submitAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 contentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external;

    /// @notice Update the content hash of an existing answer.
    ///         Requires a valid server-issued EIP-712 authorization.
    function updateAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 newContentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external;

    /// @notice Accept an answer; pays out `rewardAmount` to the responder.
    ///         Requires a valid server-issued EIP-712 authorization.
    function acceptAnswer(
        bytes32 questionId,
        bytes32 answerId,
        bytes32 questionHash,
        bytes32 contentHash,
        uint256 signedAt,
        bytes calldata signature
    ) external;

    /// @notice Delete an answer (responder only).
    ///         Requires a valid server-issued EIP-712 authorization.
    function deleteAnswer(bytes32 questionId, bytes32 answerId, uint256 signedAt, bytes calldata signature) external;

    /// @notice Delete a question that has no answers.
    ///         Requires a valid server-issued EIP-712 authorization.
    function deleteQuestion(bytes32 questionId, uint256 signedAt, bytes calldata signature) external;

    /// @notice Owner/relayer settles the question by designating a winning answer.
    function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external;

    /// @notice Owner/relayer refunds the reward to the asker.
    function adminRefund(bytes32 questionId) external;

    /// @notice Permissionless refund; callable by anyone once `deadline` has passed.
    function claimExpiredRefund(bytes32 questionId) external;

    function getQuestion(bytes32 questionId) external view returns (Question memory);
    function getQuestions(bytes32[] calldata questionIds) external view returns (Question[] memory);
    function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory);
    function getAnswers(bytes32 questionId, bytes32[] calldata answerIds) external view returns (Answer[] memory);
}
