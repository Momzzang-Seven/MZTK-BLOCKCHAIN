// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IQnAEscrow} from "./interfaces/IQnAEscrow.sol";

contract QnAEscrow is IQnAEscrow, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    // EIP-712 typehash for server-signed question creation authorization
    bytes32 private constant _CREATE_QUESTION_TYPEHASH = keccak256(
        "CreateQuestion(address creator,bytes32 questionId,address token,uint256 rewardAmount,bytes32 questionHash,uint256 nonce,uint256 signedAt)"
    );

    // State constants representing the lifecycle of a question
    uint16 public constant STATE_CREATED = 1000;
    uint16 public constant STATE_ANSWERED = 1100;
    uint16 public constant STATE_PAID_OUT = 2100; // set by acceptAnswer
    uint16 public constant STATE_ADMIN_SETTLED = 4000;
    uint16 public constant STATE_DELETED = 5000;
    uint16 public constant STATE_DELETED_WITH_ANSWERS = 5100;
    uint16 public constant STATE_DEADLINE_REFUNDED = 6000; // set by claimExpiredRefund

    // Minimum allowed escrow deadline duration (1 day) to prevent abuse
    uint48 public constant MIN_DEADLINE_DURATION = 1 days;
    // Maximum allowed escrow deadline duration (1 year)
    uint48 public constant MAX_DEADLINE_DURATION = 365 days;
    // Minimum allowed server signature validity window (1 minute)
    uint48 public constant MIN_SIG_VALIDITY_DURATION = 1 minutes;
    // Maximum allowed server signature validity window (1 hour)
    uint48 public constant MAX_SIG_VALIDITY_DURATION = 1 hours;

    // Default duration from question creation to escrow deadline: 30 days
    uint48 public defaultDeadlineDuration = 30 days;

    // Window after signedAt within which a server signature remains valid (default: 10 minutes)
    // The contract enforces this; the server only needs to include signedAt in the signature
    uint48 public sigValidityDuration = 15 minutes;

    // Server address whose EIP-712 signature is required for createQuestion
    address public signer;

    // Per-creator nonce to prevent server signature replay
    mapping(address => uint256) public nonces;

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

    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) EIP712("QnAEscrow", "1") {
        if (initialSigner == address(0)) revert InvalidAddress();
        signer = initialSigner;
        emit SignerUpdated(initialSigner);
    }

    // Updates the trusted server signer address
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidAddress();
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

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

    // Updates the default escrow deadline duration applied to new questions
    function updateDefaultDeadlineDuration(uint48 newDuration) external onlyOwner {
        if (newDuration < MIN_DEADLINE_DURATION || newDuration > MAX_DEADLINE_DURATION) revert InvalidDeadline();
        defaultDeadlineDuration = newDuration;
        emit DefaultDeadlineDurationUpdated(newDuration);
    }

    // Updates the validity window for server-issued signatures
    function updateSigValidityDuration(uint48 newDuration) external onlyOwner {
        if (newDuration < MIN_SIG_VALIDITY_DURATION || newDuration > MAX_SIG_VALIDITY_DURATION) {
            revert InvalidDeadline();
        }
        sigValidityDuration = newDuration;
        emit SigValidityDurationUpdated(newDuration);
    }

    // Creates a new question and locks the reward amount in the escrow.
    // Requires a valid EIP-712 signature from the server authorizing this specific question.
    // signedAt is the unix timestamp when the server signed; the contract checks validity
    // using sigValidityDuration (default 10 min). The server does NOT set the deadline.
    function createQuestion(
        bytes32 questionId,
        address token,
        uint256 rewardAmount,
        bytes32 questionHash,
        uint256 signedAt,
        bytes calldata signature
    ) external {
        if (token == address(0)) revert InvalidAddress();
        if (questionId == bytes32(0)) revert InvalidId();
        if (!isSupportedToken[token]) revert UnsupportedToken();
        if (rewardAmount == 0) revert InvalidRewardAmount();
        if (questions[questionId].asker != address(0)) revert QuestionAlreadyExists();
        if (questionHash == bytes32(0)) revert InvalidContentHash();

        // Verify the server-issued EIP-712 authorization
        // signedAt must be in the past, and within the allowed validity window
        if (signedAt > block.timestamp) revert InvalidSignature();
        if (block.timestamp > signedAt + sigValidityDuration) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                _CREATE_QUESTION_TYPEHASH,
                msg.sender,
                questionId,
                token,
                rewardAmount,
                questionHash,
                nonces[msg.sender],
                signedAt
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();
        nonces[msg.sender]++;

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

    // Updates the hash of an existing question
    function updateQuestion(bytes32 questionId, bytes32 newQuestionHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        // updateQuestion is only valid when no answers have been submitted yet.
        // STATE_CREATED always implies answerCount == 0 (invariant), so the answerCount check is defensive only.
        if (q.state != STATE_CREATED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAsker();
        if (newQuestionHash == bytes32(0)) revert InvalidContentHash();

        q.questionHash = newQuestionHash;
        emit QuestionUpdated(questionId, msg.sender, newQuestionHash);
    }

    // Submits a new answer to a specific question
    function submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        // Prevent griefing: submitting an answer after deadline would change claimExpiredRefund
        // from permissionless to asker-only, forcing manual intervention on an expired question.
        if (block.timestamp > q.deadline) revert DeadlineExpired();
        if (answerId == bytes32(0)) revert InvalidId();
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
        // Block updates after deadline: content changes on an expired question are meaningless
        if (block.timestamp > q.deadline) revert DeadlineExpired();

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
        // deleteQuestion is only valid when no answers exist.
        // STATE_CREATED always implies answerCount == 0 (invariant).
        if (q.state != STATE_CREATED) revert QuestionAlreadyResolved();
        if (msg.sender != q.asker) revert OnlyAsker();

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
        // Prevent admin settlement after escrow deadline so claimExpiredRefund remains valid
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

    // Administratively refunds a question by sending the reward back to the asker.
    // Intentionally has no deadline guard — refunding is always safe regardless of deadline.
    // After deadline, both adminRefund and claimExpiredRefund are callable; first caller wins.
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

    // Permissionless refund: callable by anyone once the question deadline has passed.
    // Returns locked reward to the asker without requiring relayer/owner intervention.
    // Always transitions to STATE_DEADLINE_REFUNDED regardless of answerCount.
    //
    // Safety invariant against MEV frontrunning:
    //   - STATE_CREATED (no answers): permissionless — anyone can trigger the refund.
    //   - STATE_ANSWERED (has answers): only the asker may call, because acceptAnswer
    //     is still available to them. A third party must not be able to steal the
    //     asker's chance to pay a responder by front-running this function.
    function claimExpiredRefund(bytes32 questionId) external {
        Question storage q = questions[questionId];

        if (q.asker == address(0)) revert QuestionNotFound();
        if (q.state != STATE_CREATED && q.state != STATE_ANSWERED) revert QuestionAlreadyResolved();
        if (block.timestamp <= q.deadline) revert DeadlineNotExpired();
        // Prevent third-party front-running when answers exist: only asker can forfeit
        if (q.answerCount > 0 && msg.sender != q.asker) revert OnlyAsker();

        q.state = STATE_DEADLINE_REFUNDED;
        IERC20(q.token).safeTransfer(q.asker, q.rewardAmount);

        emit DeadlineRefunded(questionId, q.asker, q.rewardAmount);
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
