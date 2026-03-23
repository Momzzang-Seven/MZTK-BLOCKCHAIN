// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IQnAEscrow} from "./interfaces/IQnAEscrow.sol";

contract QnAEscrow is IQnAEscrow, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_ANSWERED = 1100;
    uint16 public constant STATE_ACCEPTED = 2000;
    uint16 public constant STATE_PAID_OUT = 2100;
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_DELETED = 5000;
    uint16 public constant STATE_DELETED_WITH_ANSWERS = 5100;

    mapping(bytes32 => Question) public questions;
    mapping(bytes32 => mapping(bytes32 => Answer)) public answers;

    mapping(address => bool) public isSupportedToken;
    mapping(address => bool) public isRelayer;

    modifier onlyRelayerOrOwner() {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function updateTokenSupport(address token, bool isSupported) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    function updateRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    function createQuestion(bytes32 questionId, address token, uint256 rewardAmount) external {
        if (token == address(0)) revert InvalidAddress();
        if (questionId == bytes32(0)) revert InvalidAddress();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (rewardAmount == 0) revert InvalidRewardAmount();
        if (questions[questionId].asker != address(0)) revert QuestionAlreadyExists();

        questions[questionId] = Question({
            questionId: questionId,
            rewardAmount: rewardAmount,
            contentHash: bytes32(0),
            token: token,
            asker: msg.sender,
            answerCount: 0,
            state: STATE_CREATED
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit QuestionCreated(questionId, msg.sender, token, rewardAmount);
    }

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

    function acceptAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (contentHash == bytes32(0)) revert InvalidContentHash();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();

        q.state = STATE_PAID_OUT;
        q.contentHash = contentHash;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AnswerAccepted(questionId, answerId, a.responder, q.rewardAmount, contentHash);
    }

    function cancelQuestion(bytes32 questionId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.answerCount > 0) revert CannotCancelWithAnswers();

        q.state = STATE_DELETED;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit QuestionCancelled(questionId);
    }

    function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external onlyRelayerOrOwner {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (contentHash == bytes32(0)) revert InvalidContentHash();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();

        q.state = STATE_ADMIN_SETTLED;
        q.contentHash = contentHash;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AdminSettled(questionId, answerId, a.responder, q.rewardAmount, contentHash);
    }

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

    function getQuestion(bytes32 questionId) external view returns (Question memory) {
        return questions[questionId];
    }

    function getQuestions(bytes32[] calldata questionIds) external view returns (Question[] memory) {
        Question[] memory result = new Question[](questionIds.length);
        for (uint256 i = 0; i < questionIds.length; i++) {
            result[i] = questions[questionIds[i]];
        }
        return result;
    }

    function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory) {
        return answers[questionId][answerId];
    }
}
