# Contract Reference

Quick reference for all deployed contracts. For architecture and state machines,
see [architecture.md](./architecture.md).

---

## Deployed Addresses (Optimism Sepolia, chainId=11155420)

| Contract | Address |
|---|---|
| `MyERC20` (MZTK) | *(update after deploy)* |
| `MarketplaceEscrow` | *(update after deploy)* |
| `QnAEscrow` | *(update after deploy)* |
| `NonceTracker` | `0x187566a1e325705C53f097012E504BC20DF65501` |
| `DefaultReceiver` | `0x91E72675C37599Cfdf6A11E6976747e1a3E865A2` |
| `EIP7702Proxy` | `0xb5214954cC7492B0a23Ca044D16fcB381Ba1d207` |
| `BatchImplementation` | `0x8D23eD2521A8a8F7C26576171d70c06DcaC06C93` |

---

## MarketplaceEscrow

**Inherits:** `IMarketplaceEscrow`, `Ownable`

### State Constants

| Constant | Value | Meaning |
|---|---|---|
| `STATE_CREATED` | 1000 | Order placed, funds locked |
| `STATE_CONFIRMED` | 2000 | Class completed, trainer paid |
| `STATE_CANCELLED` | 3000 | Order cancelled, buyer refunded |
| `STATE_ADMIN_SETTLED` | 4000 | Admin forced payout to trainer |
| `STATE_ADMIN_REFUNDED` | 5000 | Admin forced refund to buyer |
| `STATE_DEADLINE_REFUNDED` | 6000 | Deadline expired, buyer self-refunded |

### Functions

#### Configuration (onlyOwner)

```solidity
function updateTokenSupport(address token, bool isSupported) external
```
Adds or removes an ERC20 token from the supported payment list.

```solidity
function updateRelayer(address relayer, bool isAuthorized) external
```
Grants or revokes relayer privileges for a given address.

```solidity
function updateDefaultDeadlineDuration(uint48 newDuration) external
```
Sets the deadline window applied to new orders. Minimum: `1 days`.

---

#### Order Lifecycle

```solidity
function purchaseClass(bytes32 orderId, address token, address trainer, uint256 price) external
```
Creates a new order and pulls `price` tokens from `msg.sender` into escrow.
Deadline is set to `block.timestamp + defaultDeadlineDuration`.

```solidity
function confirmClass(bytes32 orderId) external  // onlyRelayerOrOwner
```
Marks order as confirmed and transfers tokens to trainer.
Reverts if `block.timestamp > deadline`.

```solidity
function cancelClass(bytes32 orderId) external  // onlyRelayerOrOwner
```
Cancels order and refunds tokens to buyer.

```solidity
function adminSettle(bytes32 orderId) external  // onlyRelayerOrOwner
```
Force-pays trainer. Reverts if `block.timestamp > deadline`.

```solidity
function adminRefund(bytes32 orderId) external  // onlyRelayerOrOwner
```
Force-refunds buyer.

```solidity
function claimExpiredRefund(bytes32 orderId) external  // permissionless
```
Refunds buyer after deadline. Callable by anyone.
Reverts if `block.timestamp <= deadline`.

---

#### View

```solidity
function getOrder(bytes32 orderId) external view returns (ClassOrder memory)
function getOrders(bytes32[] calldata orderIds) external view returns (ClassOrder[] memory)
```

### Events

| Event | Emitted by |
|---|---|
| `ClassPurchased(orderId, buyer, trainer, token, price)` | `purchaseClass` |
| `ClassConfirmed(orderId, trainer, price)` | `confirmClass` |
| `ClassCancelled(orderId, buyer, price)` | `cancelClass` |
| `AdminSettled(orderId, trainer, price)` | `adminSettle` |
| `AdminRefunded(orderId, buyer, price)` | `adminRefund` |
| `DeadlineRefunded(orderId, buyer, price)` | `claimExpiredRefund` |
| `TokenSupportUpdated(token, isSupported)` | `updateTokenSupport` |
| `RelayerUpdated(relayer, isAuthorized)` | `updateRelayer` |
| `DefaultDeadlineDurationUpdated(newDuration)` | `updateDefaultDeadlineDuration` |

### Errors

| Error | Condition |
|---|---|
| `InvalidAddress()` | Zero address argument |
| `InvalidPrice()` | `price == 0` |
| `InvalidDeadline()` | Duration below minimum |
| `UnsupportedToken()` | Token not whitelisted |
| `OrderAlreadyExists()` | `orderId` already used |
| `OrderNotFound()` | Order does not exist |
| `AlreadySettled()` | Order not in `STATE_CREATED` |
| `CannotBuyOwnClass()` | `msg.sender == trainer` |
| `OnlyRelayerOrOwner()` | Caller lacks privilege |
| `DeadlineNotExpired()` | Called before deadline |
| `DeadlineExpired()` | Called after deadline (on settle) |

---

## QnAEscrow

**Inherits:** `IQnAEscrow`, `Ownable`

### State Constants

| Constant | Value | Meaning |
|---|---|---|
| `STATE_CREATED` | 1000 | Question posted, no answers yet |
| `STATE_ANSWERED` | 1100 | At least one answer submitted |
| `STATE_ACCEPTED` | 2000 | *(reserved, not currently used)* |
| `STATE_PAID_OUT` | 2100 | Asker accepted an answer, reward paid |
| `STATE_ADMIN_SETTLED` | 4000 | Admin forced payout |
| `STATE_DELETED` | 5000 | Deleted (no answers), reward refunded |
| `STATE_DELETED_WITH_ANSWERS` | 5100 | Deleted with answers present, reward refunded |
| `STATE_DEADLINE_REFUNDED` | 6000 | Deadline expired, asker self-refunded |

### Functions

#### Configuration (onlyOwner)

```solidity
function updateTokenSupport(address token, bool isSupported) external
function updateRelayer(address relayer, bool isAuthorized) external
function updateDefaultDeadlineDuration(uint48 newDuration) external
```

---

#### Question Lifecycle

```solidity
function createQuestion(bytes32 questionId, address token, uint256 rewardAmount, bytes32 questionHash) external
```
Creates a question and locks `rewardAmount` in escrow.
`questionHash` is the keccak256 of the off-chain content (IPFS CID or DB hash).
Deadline is set to `block.timestamp + defaultDeadlineDuration`.

```solidity
function updateQuestion(bytes32 questionId, bytes32 newQuestionHash) external
```
Updates the content hash. Only the asker can call, and only if no answers exist yet.

```solidity
function deleteQuestion(bytes32 questionId) external
```
Deletes question and refunds reward. Only asker, only when no answers exist.

```solidity
function acceptAnswer(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external
```
Asker accepts an answer. Both hashes are verified on-chain to prevent front-running.
Transfers reward to the responder.

```solidity
function adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash) external  // onlyRelayerOrOwner
```
Admin forces payout. Reverts if `block.timestamp > deadline`.

```solidity
function adminRefund(bytes32 questionId) external  // onlyRelayerOrOwner
```
Admin forces refund to asker.

```solidity
function claimExpiredRefund(bytes32 questionId) external  // permissionless
```
Refunds asker after deadline. Callable by anyone.

---

#### Answer Lifecycle

```solidity
function submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash) external
function updateAnswer(bytes32 questionId, bytes32 answerId, bytes32 newContentHash) external
function deleteAnswer(bytes32 questionId, bytes32 answerId) external
```

#### View

```solidity
function getQuestion(bytes32 questionId) external view returns (Question memory)
function getQuestions(bytes32[] calldata questionIds) external view returns (Question[] memory)
function getAnswer(bytes32 questionId, bytes32 answerId) external view returns (Answer memory)
function getAnswers(bytes32 questionId, bytes32[] calldata answerIds) external view returns (Answer[] memory)
```

### Events

| Event | Emitted by |
|---|---|
| `QuestionCreated(questionId, asker, token, rewardAmount)` | `createQuestion` |
| `QuestionUpdated(questionId, asker, newHash)` | `updateQuestion` |
| `QuestionDeleted(questionId)` | `deleteQuestion` |
| `AnswerSubmitted(questionId, answerId, responder, hash)` | `submitAnswer` |
| `AnswerUpdated(questionId, answerId, responder, hash)` | `updateAnswer` |
| `AnswerDeleted(questionId, answerId, responder)` | `deleteAnswer` |
| `AnswerAccepted(questionId, answerId, responder, amount, qHash, aHash)` | `acceptAnswer` |
| `AdminSettled(questionId, answerId, responder, amount, qHash, aHash)` | `adminSettle` |
| `AdminRefunded(questionId, asker, rewardAmount)` | `adminRefund` |
| `DeadlineRefunded(questionId, asker, rewardAmount)` | `claimExpiredRefund` |
| `TokenSupportUpdated` / `RelayerUpdated` / `DefaultDeadlineDurationUpdated` | config fns |

### Errors

| Error | Condition |
|---|---|
| `InvalidAddress()` | Zero address / zero questionId |
| `InvalidContentHash()` | Zero bytes32 hash |
| `InvalidRewardAmount()` | `rewardAmount == 0` |
| `InvalidDeadline()` | Duration below minimum |
| `UnsupportedToken()` | Token not whitelisted |
| `QuestionAlreadyExists()` | `questionId` already used |
| `AnswerAlreadyExists()` | `answerId` already used |
| `QuestionNotFound()` | Question does not exist |
| `QuestionAlreadyResolved()` | Question in terminal state |
| `OnlyAskerCanAccept()` | Caller is not the asker |
| `OnlyRelayerOrOwner()` | Caller lacks privilege |
| `AnswerNotFound()` | Answer does not exist |
| `CannotAnswerOwnQuestion()` | Asker tries to answer own question |
| `CannotDeleteWithAnswers()` | Delete attempted with answers present |
| `CannotUpdateWithAnswers()` | Update attempted with answers present |
| `OnlyResponderCanDelete()` | Non-responder tries to delete answer |
| `OnlyResponderCanUpdate()` | Non-responder tries to update answer |
| `HashMismatch()` | Provided hash does not match stored hash |
| `DeadlineNotExpired()` | `claimExpiredRefund` called before deadline |
| `DeadlineExpired()` | Settle called after deadline |
