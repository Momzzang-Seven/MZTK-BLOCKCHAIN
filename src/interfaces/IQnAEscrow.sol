// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IQnAEscrow {
    struct Question {
        bytes32 questionId;
        uint256 rewardAmount;
        bytes32 acceptedAnswerId;
        bytes32 questionHash;
        address token;
        address asker;
        uint32 answerCount;
        uint16 state;
    }

    struct Answer {
        bytes32 answerId;
        bytes32 contentHash;
        address responder;
    }

    event QuestionCreated(bytes32 indexed questionId, address indexed asker, address token, uint256 rewardAmount);

    event AnswerSubmitted(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, bytes32 contentHash
    );

    event AnswerAccepted(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address indexed responder,
        uint256 rewardAmount,
        bytes32 questionHash,
        bytes32 contentHash
    );

    event QuestionDeleted(bytes32 indexed questionId);

    event AdminSettled(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address indexed responder,
        uint256 rewardAmount,
        bytes32 questionHash,
        bytes32 contentHash
    );
    event AdminRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount);
    event AnswerDeleted(bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder);

    event QuestionUpdated(bytes32 indexed questionId, address indexed asker, bytes32 newQuestionHash);
    event AnswerUpdated(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, bytes32 newContentHash
    );

    event TokenSupportUpdated(address indexed token, bool isSupported);
    event RelayerUpdated(address indexed relayer, bool isAuthorized);

    error InvalidAddress();
    error InvalidContentHash();
    error InvalidRewardAmount();
    error UnsupportedToken();
    error QuestionAlreadyExists();
    error AnswerAlreadyExists();
    error QuestionNotFound();
    error QuestionAlreadyResolved();
    error OnlyAskerCanAccept();
    error OnlyRelayerOrOwner();
    error AnswerNotFound();
    error CannotAnswerOwnQuestion();
    error CannotDeleteWithAnswers();
    error CannotUpdateWithAnswers();
    error OnlyResponderCanDelete();
    error OnlyResponderCanUpdate();
    error HashMismatch();

    function updateTokenSupport(address token, bool isSupported) external;
    function updateRelayer(address relayer, bool isAuthorized) external;
    function createQuestion(bytes32 questionId, address token, uint256 rewardAmount, bytes32 questionHash) external;
    function submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external;
    function updateQuestion(bytes32 questionId, bytes32 newQuestionHash) external;
    function updateAnswer(bytes32 questionId, bytes32 answerId, bytes32 newContentHash) external;
    function acceptAnswer(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external;
    function deleteQuestion(bytes32 questionId) external;
    function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external;
    function adminRefund(bytes32 questionId) external;
    function getQuestion(bytes32 questionId) external view returns (Question memory);
    function getQuestions(bytes32[] calldata questionIds) external view returns (Question[] memory);
    function deleteAnswer(bytes32 questionId, bytes32 answerId) external;
    function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory);
    function getAnswers(bytes32 questionId, bytes32[] calldata answerIds) external view returns (Answer[] memory);
}
