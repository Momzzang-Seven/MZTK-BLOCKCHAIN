# 에스크로 만료/비상 탈출 — 백엔드 연동 가이드

> **대상**: MZTK-BE 백엔드 개발자  
> **관련 컨트랙트**: `MarketplaceEscrow`, `QnAEscrow`  
> **변경 커밋**: 에스크로 deadline + permissionless refund 추가

---

## 왜 추가됐는가?

기존 구조에서는 relayer/owner가 응답하지 않으면 사용자 자금이 영구적으로 컨트랙트에 묶일 수 있었습니다.  
백엔드 장애, 릴레이어 키 분실, 서버 다운 등 운영 이슈가 발생해도 **사용자가 스스로 자금을 회수할 수 있는 탈출 경로**를 컨트랙트 레벨에서 보장합니다.

---

## 핵심 변경사항

### 1. `deadline` 필드 추가

주문/질문 생성 시점에 `deadline`이 자동으로 저장됩니다.

```
deadline = block.timestamp + defaultDeadlineDuration  // 기본값: 30일
```

`deadline`은 체인에 기록되며, 백엔드에서 별도로 설정할 필요 없습니다.  
`defaultDeadlineDuration`은 owner가 `updateDefaultDeadlineDuration()`으로 변경 가능합니다 (최소 1일).

---

### 2. `claimExpiredRefund()` — 퍼미션리스 환불

deadline이 지난 주문/질문에 대해 **누구든** 호출 가능한 환불 함수입니다.

```solidity
// MarketplaceEscrow
function claimExpiredRefund(bytes32 orderId) external

// QnAEscrow
function claimExpiredRefund(bytes32 questionId) external
```

| 항목 | 내용 |
|---|---|
| 호출자 | 누구든 가능 (buyer, 제3자, 자동화 봇 포함) |
| 조건 | `state == STATE_CREATED` AND `block.timestamp > deadline` |
| 결과 | 토큰을 buyer/asker에게 환불, state → `STATE_DEADLINE_REFUNDED (6000)` |
| 릴레이어 필요 여부 | **불필요** |

---

### 3. deadline 이후 정산 차단

`deadline` 이후에는 relayer도 정산(trainer에게 지급)할 수 없습니다.

| 함수 | deadline 이후 |
|---|---|
| `confirmClass` | ❌ `DeadlineExpired` revert |
| `adminSettle` | ❌ `DeadlineExpired` revert |
| `cancelClass` | ✅ 정상 동작 (환불 방향) |
| `adminRefund` | ✅ 정상 동작 (환불 방향) |
| `claimExpiredRefund` | ✅ 이 시점부터 활성화 |

---

## 백엔드가 해야 할 일

### (선택) 만료 주문 자동 처리 배치

사용자가 직접 `claimExpiredRefund`를 호출하지 않아도, 백엔드 배치 잡이 대신 호출해줄 수 있습니다 (가스비는 백엔드가 부담).

```java
// 의사코드
List<Order> expiredOrders = orderRepository.findByStateAndDeadlineBefore(
    STATE_CREATED, Instant.now()
);
for (Order order : expiredOrders) {
    blockchainService.claimExpiredRefund(order.getOrderId());
    // state를 STATE_DEADLINE_REFUNDED로 DB 업데이트
}
```

이벤트로도 감지 가능:
```
DeadlineRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price)
DeadlineRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount)
```

### DB state 동기화

새로운 상태값이 추가됐습니다:

| 상수명 | 값 | 의미 |
|---|---|---|
| `STATE_DEADLINE_REFUNDED` | `6000` | deadline 만료 후 환불 완료 |

기존 DB의 order/question 상태 컬럼에 `6000` 값을 처리할 수 있도록 업데이트가 필요합니다.

### `deadline` 값 저장 (선택)

온체인에 저장되어 있지만, DB에도 `deadline` 컬럼을 두면 만료 배치 조회가 빠릅니다.  
`ClassPurchased` / `QuestionCreated` 이벤트 처리 시 `block.timestamp + defaultDeadlineDuration`으로 계산해서 저장하거나, `getOrder()` / `getQuestion()`으로 조회하세요.

---

## 이벤트 목록 (신규)

```solidity
// MarketplaceEscrow
event DeadlineRefunded(bytes32 indexed orderId, address indexed buyer, uint256 price);
event DefaultDeadlineDurationUpdated(uint48 newDuration);

// QnAEscrow
event DeadlineRefunded(bytes32 indexed questionId, address indexed asker, uint256 rewardAmount);
event DefaultDeadlineDurationUpdated(uint48 newDuration);
```

---

## 에러 목록 (신규)

| 에러 | 발생 조건 |
|---|---|
| `DeadlineExpired()` | deadline 이후 `confirmClass` 또는 `adminSettle` 호출 시 |
| `DeadlineNotExpired()` | deadline 이전에 `claimExpiredRefund` 호출 시 |

릴레이어가 `adminSettle`을 호출했는데 `DeadlineExpired`가 반환된다면, 해당 주문은 이미 환불 가능 상태입니다. `claimExpiredRefund`를 대신 호출하거나 사용자에게 안내하세요.

---

## 타임라인 예시 (30일 기준)

```
Day 0   purchaseClass() 호출 → escrow에 토큰 잠금, deadline = Day 30
Day 1~30  confirmClass / cancelClass / adminSettle / adminRefund 정상 동작
Day 30  deadline 도달
Day 30+ confirmClass / adminSettle → DeadlineExpired revert
Day 30+ claimExpiredRefund() → buyer에게 자동 환불 (누구든 호출 가능)
```
