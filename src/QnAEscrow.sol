// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract QnAEscrow is Ownable {
    using SafeERC20 for IERC20;



    struct Question {
        uint256 rewardAmount;
        bytes32 contentHash;
        address token;
        bool isResolved;
        address asker;
        uint40 firstAnswerTs;
        uint256 answerCount;
        bytes32 firstAnswerId;
    }

    struct Answer {
        bytes32 contentHash;
        address responder;
    }



    uint256 public constant AUTO_ACCEPT_DELAY = 7 days;

    mapping(bytes32 => Question) public questions;

    mapping(bytes32 => mapping(bytes32 => Answer)) public answers;

    mapping(address => bool) public isSupportedToken;
    
    mapping(address => bool) public isRelayer;



    event QuestionCreated(
        bytes32 indexed questionId, address indexed asker, address token, bytes32 contentHash, uint256 rewardAmount
    );

    event AnswerSubmitted(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, bytes32 contentHash
    );

    event AnswerAccepted(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, uint256 rewardAmount
    );

    event QuestionCancelled(bytes32 indexed questionId);
    
    event AdminSettled(bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, uint256 rewardAmount);
    event AdminRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount);

    event AutoAccepted(
        bytes32 indexed questionId, bytes32 indexed answerId, address indexed responder, uint256 rewardAmount
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
    error CannotCancelWithAnswers();
    error CannotAutoAcceptYet();
    error NoAnswersToAutoAccept();



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



    function createQuestion(bytes32 questionId, address token, bytes32 contentHash, uint256 rewardAmount) external {
        if (token == address(0)) revert InvalidAddress();
        if (questionId == bytes32(0)) revert InvalidAddress();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (rewardAmount == 0) revert InvalidRewardAmount();
        if (questions[questionId].asker != address(0)) revert QuestionAlreadyExists();

        questions[questionId] = Question({
            rewardAmount: rewardAmount,
            contentHash: contentHash,
            token: token,
            isResolved: false,
            asker: msg.sender,
            firstAnswerTs: 0,
            answerCount: 0,
            firstAnswerId: bytes32(0)
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit QuestionCreated(questionId, msg.sender, token, contentHash, rewardAmount);
    }

    function submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (answerId == bytes32(0)) revert InvalidAddress();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (msg.sender == q.asker) revert CannotAnswerOwnQuestion();
        if (answers[questionId][answerId].responder != address(0)) revert AnswerAlreadyExists();

        if (q.answerCount == 0) {
            q.firstAnswerTs = uint40(block.timestamp);
            q.firstAnswerId = answerId;
        }

        q.answerCount += 1;
        answers[questionId][answerId] = Answer({
            contentHash: contentHash,
            responder: msg.sender
        });

        emit AnswerSubmitted(questionId, answerId, msg.sender, contentHash);
    }

    function acceptAnswer(bytes32 questionId, bytes32 answerId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();

        q.isResolved = true;

        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AnswerAccepted(questionId, answerId, a.responder, q.rewardAmount);
    }

    function cancelQuestion(bytes32 questionId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.answerCount > 0) revert CannotCancelWithAnswers();

        q.isResolved = true;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit QuestionCancelled(questionId);
    }

    function autoAcceptFirstAnswer(bytes32 questionId) external onlyRelayerOrOwner {
        _autoAcceptFirstAnswer(questionId);
    }

    function batchAutoAcceptFirstAnswer(bytes32[] calldata questionIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < questionIds.length; i++) {
            _autoAcceptFirstAnswer(questionIds[i]);
        }
    }

    function adminSettle(bytes32 questionId, bytes32 answerId) external onlyRelayerOrOwner {
        _adminSettle(questionId, answerId);
    }

    function batchAdminSettle(bytes32[] calldata questionIds, bytes32[] calldata answerIds) external onlyRelayerOrOwner {
        require(questionIds.length == answerIds.length, "Array length mismatch");
        for (uint256 i = 0; i < questionIds.length; i++) {
            _adminSettle(questionIds[i], answerIds[i]);
        }
    }

    function adminRefund(bytes32 questionId) external onlyRelayerOrOwner {
        _adminRefund(questionId);
    }

    function batchAdminRefund(bytes32[] calldata questionIds) external onlyRelayerOrOwner {
        for (uint256 i = 0; i < questionIds.length; i++) {
            _adminRefund(questionIds[i]);
        }
    }



    function _autoAcceptFirstAnswer(bytes32 questionId) internal {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (q.answerCount == 0) revert NoAnswersToAutoAccept();
        
        if (block.timestamp < q.firstAnswerTs + AUTO_ACCEPT_DELAY) {
            revert CannotAutoAcceptYet();
        }

        bytes32 answerId = q.firstAnswerId;
        Answer storage a = answers[questionId][answerId];
        
        q.isResolved = true;
        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AutoAccepted(questionId, answerId, a.responder, q.rewardAmount);
    }

    function _adminSettle(bytes32 questionId, bytes32 answerId) internal {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();

        Answer storage a = answers[questionId][answerId];
        if (a.responder == address(0)) revert AnswerNotFound();

        q.isResolved = true;
        IERC20(q.token).safeTransfer(a.responder, q.rewardAmount);

        emit AdminSettled(questionId, answerId, a.responder, q.rewardAmount);
    }

    function _adminRefund(bytes32 questionId) internal {
        Question storage q = questions[questionId];
        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();

        q.isResolved = true;
        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit AdminRefunded(questionId, q.asker, q.rewardAmount);
    }



    function getQuestion(bytes32 questionId) external view returns (Question memory) {
        return questions[questionId];
    }

    function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory) {
        return answers[questionId][answerId];
    }
}
