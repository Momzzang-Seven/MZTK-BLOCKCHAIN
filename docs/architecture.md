# Contract Architecture

## System Overview

```
┌─────────────┐        RPC calls       ┌──────────────────┐
│  MZTK-FE    │ ─────────────────────► │  Optimism Sepolia │
│  (React.js)  │                       │                   │
└─────────────┘                        │  MarketplaceEscrow│
                                       │  QnAEscrow        │
┌─────────────┐   relayer tx (signed)  │  EIP7702Proxy     │
│  MZTK-BE    │ ─────────────────────► │  BatchImpl        │
│ (Spring Boot│                        │  MyERC20 (MZTK)   │
└─────────────┘                        └──────────────────┘
```

The backend acts as a **trusted relayer** — it is whitelisted in both escrow contracts
and submits on-chain transactions on behalf of users after validating off-chain business logic.

---

## Contract Dependency Graph

```
MarketplaceEscrow
  ├── IMarketplaceEscrow (interface)
  ├── OZ: IERC20, SafeERC20, Ownable

QnAEscrow
  ├── IQnAEscrow (interface)
  ├── OZ: IERC20, SafeERC20, Ownable

EIP7702Proxy
  ├── IAccountStateValidator (interface)
  ├── NonceTracker
  ├── OZ: Proxy, ERC1967Utils, ECDSA

BatchImplementation
  └── OZ: ECDSA

MyERC20
  └── OZ: ERC20
```

---

## MarketplaceEscrow

### Purpose
Holds buyer payment in escrow for class purchases. Funds are released to the trainer
only after the class is confirmed, or refunded to the buyer on cancellation/expiry.

### Roles
| Role | Address | Permissions |
|---|---|---|
| Owner | Deployer EOA | Config only (tokens, relayers, deadline duration) |
| Relayer | Backend hot wallet | `confirmClass`, `cancelClass`, `adminSettle`, `adminRefund` |
| Buyer | Any EOA | `purchaseClass`, `claimExpiredRefund` (after deadline) |

### Order State Machine

```
                     purchaseClass()
                          │
                          ▼
                    ┌──────────┐
           ┌───────►│ CREATED  │◄─────────────────────────────────┐
           │        │  (1000)  │                                   │
           │        └──────────┘                                   │
           │          │  │  │  │                                   │
  cancelClass()  confirmClass() adminSettle() adminRefund()  claimExpiredRefund()
    refund→buyer  pay→trainer   pay→trainer   refund→buyer   refund→buyer (permissionless)
           │          │  │  │  │                                   │
           ▼          ▼  │  ▼  ▼                                   │
      CANCELLED   CONFIRMED  ADMIN_SETTLED  ADMIN_REFUNDED  DEADLINE_REFUNDED
       (3000)      (2000)      (4000)         (5000)           (6000)
```

> **Deadline guard**: `confirmClass` and `adminSettle` revert if `block.timestamp > deadline`.
> `cancelClass` and `adminRefund` do **not** check deadline (they refund the buyer, which is safe).

### Struct Layout (`ClassOrder`)

```solidity
struct ClassOrder {
    bytes32 orderId;    // 32 bytes — unique identifier
    uint256 price;      // 32 bytes — locked token amount
    address token;      // 20 bytes ─┐
    uint48  deadline;   //  6 bytes  │ packed into one slot
    uint16  state;      //  2 bytes ─┘
    address buyer;      // 20 bytes ─┐ packed
    address trainer;    // 20 bytes ─┘ (two addresses = 40 bytes → two slots)
}
```

---

## QnAEscrow

### Purpose
Holds asker reward in escrow while a question is open. Reward is released to the
accepted responder, or refunded to the asker on deletion/expiry.

### Roles
| Role | Permissions |
|---|---|
| Owner | Config (tokens, relayers, deadline duration) |
| Relayer | `adminSettle`, `adminRefund` |
| Asker | `createQuestion`, `updateQuestion`, `deleteQuestion`, `acceptAnswer`, `claimExpiredRefund` |
| Responder | `submitAnswer`, `updateAnswer`, `deleteAnswer` |

### Question State Machine

```
             createQuestion()
                   │
                   ▼
             ┌──────────┐   submitAnswer()   ┌──────────────┐
             │ CREATED  │──────────────────►  │   ANSWERED   │
             │  (1000)  │◄──────────────────  │    (1100)    │
             └──────────┘  deleteAnswer()     └──────────────┘
               │  │  │                          │  │  │
   deleteQ() adminRefund() claimExpired()  acceptAnswer() adminSettle() claimExpired()
   (no answers)            (permissionless)              (relayer)     (permissionless)
               │  │  │                          │  │  │
               ▼  ▼  ▼                          ▼  ▼  ▼
          DELETED DELETED  DEADLINE_REFUNDED PAID_OUT ADMIN_SETTLED DEADLINE_REFUNDED
          (5000) _WITH_ANS    (6000)          (2100)    (4000)        (6000)
                  (5100)
```

### Struct Layout (`Question`)

```solidity
struct Question {
    bytes32 questionId;      // 32 bytes
    uint256 rewardAmount;    // 32 bytes
    bytes32 acceptedAnswerId;// 32 bytes
    bytes32 questionHash;    // 32 bytes — IPFS/content hash of question
    address token;           // 20 bytes ─┐
    uint48  deadline;        //  6 bytes  │ packed into one slot
    address asker;           // 20 bytes  │ (next slot)
    uint32  answerCount;     //  4 bytes ─┘
    uint16  state;           //  2 bytes
}
```

---

## EIP-7702 Account System

### Purpose
Allows EOAs to temporarily behave like smart contract accounts by setting an
EIP-7702 designation pointing to `EIP7702Proxy`. The proxy delegates calls
to a configurable implementation (e.g. `BatchImplementation`).

### Flow

```
EOA (EIP-7702 designation → EIP7702Proxy)
  │
  │  setImplementation(newImpl, callData, validator, expiry, sig)
  │  ──► verifies EIP-712 sig signed by the EOA itself
  │  ──► upgrades implementation slot (ERC-1967)
  │  ──► optionally calls validator hook
  │
  │  execute(calls[], signature)     ← via BatchImplementation
  │  ──► verifies EIP-712 batch sig
  │  ──► replays each Call atomically
  └─────────────────────────────────────────────────────────────
```

### Replay Protection
- `NonceTracker` maintains a per-account nonce consumed on each `setImplementation` call.
- `BatchImplementation.txNonce` provides a separate sequential nonce for batch execution.

---

## Security Model

| Threat | Mitigation |
|---|---|
| Relayer goes offline | `claimExpiredRefund()` — permissionless after deadline |
| Token pause/blacklist | Deadline refund unblocks asker regardless of token state |
| Double-spend on terminal state | All terminal states are `!=STATE_CREATED`, gating every write |
| Relayer settles after deadline | `DeadlineExpired` guard on `confirmClass` / `adminSettle` |
| Replay attacks (EIP-7702) | `NonceTracker` + `txNonce` in `BatchImplementation` |
| Admin draining escrow | No owner-withdraw function; funds only flow per-order |
