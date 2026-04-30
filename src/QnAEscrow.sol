// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IQnAEscrow} from "./interfaces/IQnAEscrow.sol";

contract QnAEscrow is IQnAEscrow, Ownable {
    using SafeERC20 for IERC20;

    // State constants representing the lifecycle of a question
    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_ANSWERED = 1100;
    uint16 public constant STATE_ACCEPTED = 2000;
    uint16 public constant STATE_PAID_OUT = 2100;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_DELETED = 5000;
    uint16 public constant STATE_DELETED_WITH_ANSWERS = 5100;

    // Mapping from question ID to Question details
    mapping(bytes32 => Question) public questions;
    // Mapping from question ID and answer ID to Answer details
    mapping(bytes32 => mapping(bytes32 => Answer)) public answers;

    // Mapping to track supported ERC20 tokens for payment
    mapping(address => bool) public isSupportedToken;
    // Mapping to track authorized relayer addresses
    mapping(address => bool) public isRelayer;

    // Modifier to restrict access to only relayer or owner
    modifier onlyRelayerOrOwner() {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    // Updates the support status of an ERC20 token
    function updateTokenSupport(address token, bool isSupported) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    // Updates the authorization status of a relayer
    function updateRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    // Creates a new question and locks the reward amount in the escrow
    function createQuestion(bytes32 questionId, address token, uint256 rewardAmount, bytes32 questionHash) external {
        if (token == address(0)) revert InvalidAddress();
        if (questionId == bytes32(0)) revert InvalidAddress();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (rewardAmount == 0) revert InvalidRewardAmount();
        if (questions[questionId].asker != address(0)) revert QuestionAlreadyExists();
        if (questionHash == bytes32(0)) revert InvalidContentHash();

        questions[questionId] = Question({
            questionId: questionId,
            rewardAmount: rewardAmount,
            acceptedAnswerId: bytes32(0),
            questionHash: questionHash,
            token: token,
            asker: msg.sender,
            answerCount: 0,
            state: STATE_CREATED
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit QuestionCreated(questionId, msg.sender, token, rewardAmount);
    }

    // Updates the hash of an existing question
    function updateQuestion(bytes32 questionId, bytes32 newQuestionHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.answerCount > 0) revert CannotUpdateWithAnswers();
        if (newQuestionHash == bytes32(0)) revert InvalidContentHash();

        q.questionHash = newQuestionHash;
        emit QuestionUpdated(questionId, msg.sender, newQuestionHash);
    }

    // Submits a new answer to a specific question
    function submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (answerId == bytes32(0)) revert InvalidAddress();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (msg.sender == q.asker) revert CannotAnswerOwnQuestion();
        if (answers[questionId][answerId].responder != address(0)) revert AnswerAlreadyExists();

        if (q.state == STATE_CREATED) {
            q.state = STATE_ANSWERED;
        }

        q.answerCount += 1;
        answers[questionId][answerId] = Answer({answerId: answerId, contentHash: contentHash, responder: msg.sender});

        emit AnswerSubmitted(questionId, answerId, msg.sender, contentHash);
    }

    // Updates the hash of an existing answer
    function updateAnswer(bytes32 questionId, bytes32 answerId, bytes32 newContentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (msg.sender != a.responder) revert OnlyResponderCanUpdate();
        if (newContentHash == bytes32(0)) revert InvalidContentHash();

        a.contentHash = newContentHash;
        emit AnswerUpdated(questionId, answerId, msg.sender, newContentHash);
    }

    // Deletes an answer submitted by the user
    function deleteAnswer(bytes32 questionId, bytes32 answerId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (msg.sender != a.responder) revert OnlyResponderCanDelete();

        address responder = a.responder;
        delete answers[questionId][answerId];

        q.answerCount -= 1;
        if (q.answerCount == 0) {
            q.state = STATE_CREATED;
        }

        emit AnswerDeleted(questionId, answerId, responder);
    }

    // Accepts an answer and transfers the locked reward to the responder
    function acceptAnswer(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.questionHash != questionHash) revert HashMismatch();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (a.contentHash != contentHash) revert HashMismatch();

        q.state = STATE_PAID_OUT;
        q.acceptedAnswerId = answerId;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AnswerAccepted(questionId, answerId, a.responder, q.rewardAmount, questionHash, contentHash);
    }

    // Deletes a question and refunds the locked reward to the asker
    function deleteQuestion(bytes32 questionId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.answerCount > 0) revert CannotDeleteWithAnswers();

        q.state = STATE_DELETED;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit QuestionDeleted(questionId);
    }

    // Administratively settles a question by paying the reward to a responder
    function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash)
        external
        onlyRelayerOrOwner
    {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (q.questionHash != questionHash) revert HashMismatch();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();
        if (a.contentHash != contentHash) revert HashMismatch();

        q.state = STATE_ADMIN_SETTLED;
        q.acceptedAnswerId = answerId;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AdminSettled(questionId, answerId, a.responder, q.rewardAmount, questionHash, contentHash);
    }

    // Administratively refunds a question by sending the reward back to the asker
    function adminRefund(bytes32 questionId) external onlyRelayerOrOwner {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();

        if (q.answerCount > 0) {
            q.state = STATE_DELETED_WITH_ANSWERS;
        } else {
            q.state = STATE_DELETED;
        }

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit AdminRefunded(questionId, q.asker, q.rewardAmount);
    }

    // Retrieves the details of a specific question
    function getQuestion(bytes32 questionId) external view returns (Question memory) {
        return questions[questionId];
    }

    // Retrieves the details of multiple questions
    function getQuestions(bytes32[] calldata questionIds) external view returns (Question[] memory) {
        Question[] memory result = new Question[](questionIds.length);
        for (uint256 i = 0; i < questionIds.length; i++) {
            result[i] = questions[questionIds[i]];
        }
        return result;
    }

    // Retrieves the details of a specific answer
    function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory) {
        return answers[questionId][answerId];
    }

    // Retrieves the details of multiple answers for a specific question
    function getAnswers(bytes32 questionId, bytes32[] calldata answerIds) external view returns (Answer[] memory) {
        Answer[] memory result = new Answer[](answerIds.length);
        for (uint256 i = 0; i < answerIds.length; i++) {
            result[i] = answers[questionId][answerIds[i]];
        }
        return result;
    }
}
