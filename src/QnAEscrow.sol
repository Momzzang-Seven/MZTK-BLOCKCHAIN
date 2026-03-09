// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title QnAEscrow
 * @notice 질문 게시판 에스크로 컨트랙트 (MarketplaceEscrow 동기화 버전)
 */
contract QnAEscrow {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Types ────────────────────────────

    struct Question {
        address asker;
        address token;
        bytes32 contentHash;
        uint256 rewardAmount;
        bool isResolved;
        uint256 answerCount;
    }

    struct Answer {
        address responder;
        bytes32 contentHash;
    }

    // ──────────────────────────── State ────────────────────────────

    uint256 public questionCount;

    /// @dev questionId => Question
    mapping(uint256 => Question) public questions;

    /// @dev questionId => answerId => Answer
    mapping(uint256 => mapping(uint256 => Answer)) public answers;

    // ──────────────────────────── Events ───────────────────────────

    event QuestionCreated(
        uint256 indexed questionId, address indexed asker, address token, bytes32 contentHash, uint256 rewardAmount
    );

    event AnswerSubmitted(
        uint256 indexed questionId, uint256 indexed answerId, address indexed responder, bytes32 contentHash
    );

    event AnswerAccepted(
        uint256 indexed questionId, uint256 indexed answerId, address indexed responder, uint256 rewardAmount
    );

    event QuestionCancelled(uint256 indexed questionId);

    // ──────────────────────────── Errors ───────────────────────────

    error InvalidAddress();
    error InvalidContentHash();
    error InvalidRewardAmount();
    error QuestionNotFound();
    error QuestionAlreadyResolved();
    error OnlyAskerCanAccept();
    error AnswerNotFound();
    error CannotAnswerOwnQuestion();
    error CannotCancelWithAnswers();

    // ────────────────────────── Constructor ────────────────────────

    constructor() {}

    // ──────────────────────── External Functions ───────────────────

    /**
     * @notice 질문 등록 + ERC-20 토큰 예치
     */
    function createQuestion(address token, bytes32 contentHash, uint256 rewardAmount)
        external
        returns (uint256 questionId)
    {
        if (token == address(0)) revert InvalidAddress();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (rewardAmount == 0) revert InvalidRewardAmount();

        questionId = questionCount++;

        questions[questionId] = Question({
            asker: msg.sender,
            token: token,
            contentHash: contentHash,
            rewardAmount: rewardAmount,
            isResolved: false,
            answerCount: 0
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit QuestionCreated(questionId, msg.sender, token, contentHash, rewardAmount);
    }

    /**
     * @notice 답변 등록
     */
    function submitAnswer(uint256 questionId, bytes32 contentHash) external returns (uint256 answerId) {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (msg.sender == q.asker) revert CannotAnswerOwnQuestion();

        answerId = q.answerCount++;

        answers[questionId][answerId] = Answer({responder: msg.sender, contentHash: contentHash});

        emit AnswerSubmitted(questionId, answerId, msg.sender, contentHash);
    }

    /**
     * @notice 답변 채택 → 예치된 토큰을 답변자에게 전송
     */
    function acceptAnswer(uint256 questionId, uint256 answerId) external {
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

    /**
     * @notice 질문 취소 → 답변이 없을 때만 예치금 환불
     */
    function cancelQuestion(uint256 questionId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.isResolved) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAskerCanAccept();
        if (q.answerCount > 0) revert CannotCancelWithAnswers();

        q.isResolved = true;

        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit QuestionCancelled(questionId);
    }

    // ──────────────────────── View Functions ──────────────────────

    function getQuestion(uint256 questionId)
        external
        view
        returns (
            address asker,
            address token,
            bytes32 contentHash,
            uint256 rewardAmount,
            bool isResolved,
            uint256 answerCount
        )
    {
        Question storage q = questions[questionId];
        return (q.asker, q.token, q.contentHash, q.rewardAmount, q.isResolved, q.answerCount);
    }

    function getAnswer(uint256 questionId, uint256 answerId)
        external
        view
        returns (address responder, bytes32 contentHash)
    {
        Answer storage a = answers[questionId][answerId];
        return (a.responder, a.contentHash);
    }
}
