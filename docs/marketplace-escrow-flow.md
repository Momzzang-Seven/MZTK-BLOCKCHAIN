# MarketplaceEscrow — 개발자 연동 가이드

> **대상**: MZTK-BE (Spring/Java), MZTK-FE (TypeScript/ethers.js)  
> **컨트랙트**: `src/MarketplaceEscrow.sol`  
> **네트워크**:  
> - Optimism Sepolia (chainId: 11155420): `0x872070a70b291caC3Dc65DaA50670b22dcf739Ff`  
> - Base Sepolia (chainId: 84532): `0x2955e5239077B8C1010F6F670152DA11F0b487d0`

---

## 1. 전체 흐름 한눈에 보기

```
[사용자(buyer) - FE]    [백엔드 - BE]           [컨트랙트 - MarketplaceEscrow]
      │                     │                              │
      │ 1. 클래스 구매 요청  │                              │
      │────────────────────►│                              │
      │                     │ 2. orderId 발급 (DB int)     │
      │                     │    EIP-712 서명 생성         │
      │◄────────────────────│                              │
      │ 3. payload 수신     │                              │
      │    (signedAt, sig)  │                              │
      │                     │                              │
      │ 4. approve + purchaseClass tx 전송                 │
      │────────────────────────────────────────────────────►
      │                     │                              │ 5. 검증 & 토큰 잠금
      │ 5. txHash → BE 전달 │                              │
      │────────────────────►│                              │
      │                     │ 6. receipt 조회 & 파싱       │
      │                     │    DB 상태 = ESCROWED        │
      │◄────────────────────│                              │
      │ 7. 완료 응답        │                              │
      │                     │                              │
      │ (수업 완료 후)       │                              │
      │ 8. confirmClass tx  │                              │
      │────────────────────────────────────────────────────►
      │                     │                              │ 9. 토큰 → trainer
      │ 9. txHash → BE 전달 │                              │
      │────────────────────►│                              │
      │                     │ 10. receipt 파싱             │
      │                     │     DB 상태 = CONFIRMED      │
```

---

## 2. 백엔드 구현 (Spring / Java)

### 2-1. 상수 정의

```java
// TypeHash — 컨트랙트의 _PURCHASE_CLASS_TYPEHASH와 정확히 일치해야 함
private static final String TYPE_STRING =
    "PurchaseClass(address buyer,bytes32 orderId,address token," +
    "address trainer,uint256 price,uint256 signedAt)";

private static final byte[] PURCHASE_CLASS_TYPEHASH =
    Hash.sha3(TYPE_STRING.getBytes(StandardCharsets.UTF_8));

// 도메인 세퍼레이터 구성 요소
private static final String DOMAIN_NAME    = "MarketplaceEscrow";
private static final String DOMAIN_VERSION = "1";
```

### 2-2. EIP-712 서명 생성 (전체 코드)

```java
public byte[] signPurchaseClass(
    String  buyerAddress,    // 구매자 지갑 주소
    long    dbOrderId,       // DB의 주문 ID (int)
    String  tokenAddress,    // MZTK 토큰 주소
    String  trainerAddress,  // 강사 지갑 주소
    BigInteger price,        // wei 단위
    ECKeyPair serverKeyPair  // 서버 private key
) {
    // 1. signedAt = 현재 시각
    BigInteger signedAt = BigInteger.valueOf(Instant.now().getEpochSecond());

    // 2. DB int → bytes32 패딩
    byte[] orderIdBytes = Numeric.toBytesPadded(BigInteger.valueOf(dbOrderId), 32);

    // 3. 구조체 해시
    byte[] structHash = Hash.sha3(
        encodePacked(
            PURCHASE_CLASS_TYPEHASH,
            Numeric.hexStringToByteArray(buyerAddress),   // address (32byte 패딩)
            orderIdBytes,                                  // bytes32
            Numeric.hexStringToByteArray(tokenAddress),   // address (32byte 패딩)
            Numeric.hexStringToByteArray(trainerAddress), // address (32byte 패딩)
            Numeric.toBytesPadded(price, 32),             // uint256
            Numeric.toBytesPadded(signedAt, 32)           // uint256
        )
    );

    // 4. 도메인 세퍼레이터 (QnA와 name만 다름)
    byte[] domainSeparator = buildDomainSeparator(contractAddress, chainId);

    // 5. 최종 digest
    byte[] digest = Hash.sha3(
        concat(new byte[]{0x19, 0x01}, domainSeparator, structHash)
    );

    // 6. 서버 서명 (r + s + v, 65 bytes)
    Sign.SignatureData sig = Sign.signMessage(digest, serverKeyPair, false);
    return concat(sig.getR(), sig.getS(), sig.getV());
}

private byte[] buildDomainSeparator(String contractAddress, long chainId) {
    byte[] domainTypeHash = Hash.sha3(
        ("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        .getBytes(StandardCharsets.UTF_8)
    );
    return Hash.sha3(encodePacked(
        domainTypeHash,
        Hash.sha3(DOMAIN_NAME.getBytes(StandardCharsets.UTF_8)),
        Hash.sha3(DOMAIN_VERSION.getBytes(StandardCharsets.UTF_8)),
        Numeric.toBytesPadded(BigInteger.valueOf(chainId), 32),
        Numeric.hexStringToByteArray(contractAddress) // 32byte 패딩
    ));
}
```

### 2-4. FE에 반환할 payload

```json
{
  "orderId": "0x0000000000000000000000000000000000000000000000000000000000000042",
  "tokenAddress": "0xMZTK_TOKEN_ADDRESS",
  "trainerAddress": "0xTRAINER_WALLET",
  "price": "100000000000000000000",
  "signedAt": 1714567890,
  "serverSig": "0xaabbcc...65bytes"
}
```

### 2-5. Receipt 기반 DB 상태 동기화

FE가 tx 전송 후 `txHash`를 BE에 전달하면, BE가 receipt를 조회해서 파싱합니다.

#### 흐름

```
FE: tx 전송 → txHash 획득
FE → BE: POST /api/orders/confirm { txHash }
BE: eth_getTransactionReceipt(txHash) 조회
BE: receipt.status 확인 + logs 이벤트 파싱
BE: DB 업데이트 후 응답
```

#### Java / Web3j 구현

```java
public OrderConfirmResult confirmByReceipt(String txHash) throws Exception {

    // 1. receipt 조회 (pending이면 polling)
    TransactionReceipt receipt = waitForReceipt(txHash, 10, 3000);

    // 2. 실패 tx 차단
    if (!receipt.isStatusOK()) {
        throw new TransactionFailedException("Transaction reverted: " + txHash);
    }

    // 3. ClassPurchased 이벤트 파싱
    List<MarketplaceEscrow.ClassPurchasedEventResponse> events =
        marketplaceEscrowContract.getClassPurchasedEvents(receipt);

    if (events.isEmpty()) {
        throw new EventNotFoundException("ClassPurchased event not found");
    }

    ClassPurchasedEventResponse event = events.get(0);

    // 4. DB 업데이트
    long orderId = event.orderId.toBigInteger().longValue();
    orderRepository.updateStatus(orderId, "ESCROWED");

    return new OrderConfirmResult(orderId, txHash);
}

// Polling 유틸리티
public TransactionReceipt waitForReceipt(String txHash, int maxRetry, long intervalMs)
        throws Exception {
    for (int i = 0; i < maxRetry; i++) {
        Optional<TransactionReceipt> opt = web3j
            .ethGetTransactionReceipt(txHash).send()
            .getTransactionReceipt();
        if (opt.isPresent()) return opt.get();
        Thread.sleep(intervalMs);
    }
    throw new TimeoutException("Receipt timeout: " + txHash);
}
```

#### 함수별 파싱 이벤트 & DB 매핑

| 호출 함수 | receipt에서 파싱할 이벤트 | DB 업데이트 |
|---|---|---|
| `purchaseClass` | `ClassPurchased` | status = `ESCROWED` |
| `confirmClass` | `ClassConfirmed` | status = `CONFIRMED` |
| `cancelClass` | `ClassCancelled` | status = `CANCELLED` |
| `adminSettle` | `AdminSettled` | status = `ADMIN_SETTLED` |
| `adminRefund` | `AdminRefunded` | status = `ADMIN_REFUNDED` |
| `claimExpiredRefund` | `DeadlineRefunded` | status = `DEADLINE_REFUNDED` |

---

## 3. 프론트엔드 구현 (TypeScript / ethers.js v6)

### 3-1. purchaseClass (클래스 구매)

```typescript
import { ethers } from "ethers";

async function purchaseClass(payload: {
  orderId: string;      // bytes32 hex
  tokenAddress: string;
  trainerAddress: string;
  price: bigint;
  signedAt: number;
  serverSig: string;    // 65-byte hex
}) {
  const signer = await provider.getSigner();

  // 1. ERC20 approve
  const token = new ethers.Contract(payload.tokenAddress, ERC20_ABI, signer);
  const approveTx = await token.approve(MARKETPLACE_ESCROW_ADDRESS, payload.price);
  await approveTx.wait();

  // 2. purchaseClass 호출
  const escrow = new ethers.Contract(MARKETPLACE_ESCROW_ADDRESS, MARKETPLACE_ABI, signer);
  const tx = await escrow.purchaseClass(
    payload.orderId,
    payload.tokenAddress,
    payload.trainerAddress,
    payload.price,
    payload.signedAt,
    payload.serverSig
  );

  const receipt = await tx.wait();

  if (receipt.status === 1) {
    // txHash를 BE로 전달
    await api.post("/orders/confirm", { txHash: tx.hash });
  }
}
```

### 3-2. confirmClass (수업 완료 확인 → 강사에게 지급)

```typescript
async function confirmClass(orderId: string) {
  const escrow = new ethers.Contract(MARKETPLACE_ESCROW_ADDRESS, MARKETPLACE_ABI, signer);
  const tx = await escrow.confirmClass(orderId);
  const receipt = await tx.wait();

  if (receipt.status === 1) {
    await api.post("/orders/settled", { txHash: tx.hash });
  }
}
```

> ⚠️ `confirmClass`는 **deadline(30일) 이전에만** 가능합니다.  
> 만료 후에는 `DeadlineExpired` revert — 만료 전에 수업 완료를 확인해야 합니다.

### 3-3. cancelClass (취소 → buyer 환불)

```typescript
async function cancelClass(orderId: string) {
  // buyer 또는 trainer 둘 다 호출 가능
  const escrow = new ethers.Contract(MARKETPLACE_ESCROW_ADDRESS, MARKETPLACE_ABI, signer);
  const tx = await escrow.cancelClass(orderId);
  await tx.wait();
  await api.post("/orders/cancelled", { txHash: tx.hash });
}
```

### 3-4. claimExpiredRefund (deadline 만료 후 비상 환불)

```typescript
async function claimExpiredRefund(orderId: string) {
  // deadline 이후면 누구나 호출 가능 (buyer가 호출하는 것이 자연스러움)
  const escrow = new ethers.Contract(MARKETPLACE_ESCROW_ADDRESS, MARKETPLACE_ABI, signer);
  const tx = await escrow.claimExpiredRefund(orderId);
  await tx.wait();
  await api.post("/orders/expired-refund", { txHash: tx.hash });
}
```

### 3-5. 에러 처리

```typescript
try {
  const tx = await escrow.purchaseClass(...);
} catch (err: any) {
  const errorName = escrow.interface.parseError(err.data)?.name;
  switch (errorName) {
    case "SignatureExpired":
      await refreshServerSignature(); // BE에 서명 재발급 요청
      break;
    case "InvalidSignature":
      await refreshServerSignature(); // 서명 오류 → BE에 재발급 요청
      break;
    case "OrderAlreadyExists":
      showError("이미 구매된 주문입니다.");
      break;
    case "CannotBuyOwnClass":
      showError("본인의 클래스는 구매할 수 없습니다.");
      break;
    case "DeadlineExpired":
      showError("주문 기한이 만료되었습니다. 환불을 요청하세요.");
      break;
    case "AlreadySettled":
      showError("이미 처리된 주문입니다.");
      break;
    default:
      showError("트랜잭션 실패: " + errorName);
  }
}
```

### 3-6. orderId 인코딩

```typescript
// DB int → bytes32 (zero left-pad)
const orderId = ethers.zeroPadValue(ethers.toBeHex(dbOrderId), 32);
// 예: dbOrderId = 66 → "0x0000...0042"
```

---

## 4. 컨트랙트 함수 전체 참조

### purchaseClass

```solidity
function purchaseClass(
    bytes32 orderId,       // DB int를 bytes32로 left-pad
    address token,         // MZTK 토큰 주소
    address trainer,       // 강사 지갑 주소
    uint256 price,         // wei 단위
    uint256 signedAt,      // 서버 서명 시각 (unix timestamp, seconds)
    bytes calldata signature // 서버 EIP-712 서명 (65 bytes: r+s+v)
) external
```

**검증 순서 & 에러:**

| 순서 | 조건 | 에러 |
|---|---|---|
| 1 | `token != address(0)` && `trainer != address(0)` | `InvalidAddress` |
| 2 | `orderId != bytes32(0)` | `InvalidId` |
| 3 | `isSupportedToken[token]` | `UnsupportedToken` |
| 4 | `price > 0` | `InvalidPrice` |
| 5 | `msg.sender != trainer` | `CannotBuyOwnClass` |
| 6 | 중복 orderId 없음 | `OrderAlreadyExists` |
| 7a | `signedAt <= block.timestamp` | `InvalidSignature` |
| 7b | `block.timestamp <= signedAt + 15분` | `SignatureExpired` |
| 8 | 서명 복원 주소 == signer | `InvalidSignature` |

### 그 외 함수

```solidity
// 수업 완료 확인 → 강사에게 지급 (deadline 이전만, buyer만 호출 가능)
confirmClass(bytes32 orderId)

// 취소 → buyer 환불 (deadline 무관, buyer 또는 trainer 호출 가능)
cancelClass(bytes32 orderId)

// 관리자 정산 → 강사에게 지급 (deadline 이전만)
adminSettle(bytes32 orderId)

// 관리자 환불 → buyer 환불 (deadline 무관)
adminRefund(bytes32 orderId)

// 비상 환불 → buyer 환불 (deadline 이후 누구나 호출 가능)
claimExpiredRefund(bytes32 orderId)
```

---

## 5. 상태 머신

```
purchaseClass()
      │
      ▼
  CREATED (1000)  ─── 토큰 잠금 상태
      │
      ├─ confirmClass()     → CONFIRMED (2000)        [deadline 이전, buyer만]
      │                        토큰 → trainer
      │
      ├─ cancelClass()      → CANCELLED (3000)        [deadline 무관]
      │                        토큰 → buyer             buyer 또는 trainer 가능
      │
      ├─ adminSettle()      → ADMIN_SETTLED (4000)    [deadline 이전, relayer/owner]
      │                        토큰 → trainer
      │
      ├─ adminRefund()      → ADMIN_REFUNDED (5000)   [deadline 무관, relayer/owner]
      │                        토큰 → buyer
      │
      └─ claimExpiredRefund() → DEADLINE_REFUNDED (6000)  [deadline 이후, 누구나]
                                  토큰 → buyer
```

**상태 코드 상수:**

| 상수명 | 값 | 의미 |
|---|---|---|
| `STATE_CREATED` | 1000 | 구매 완료, 토큰 잠금 |
| `STATE_CONFIRMED` | 2000 | buyer가 수업 완료 확인, 강사에게 지급 |
| `STATE_CANCELLED` | 3000 | 취소됨, buyer 환불 |
| `STATE_ADMIN_SETTLED` | 4000 | 관리자 정산, 강사에게 지급 |
| `STATE_ADMIN_REFUNDED` | 5000 | 관리자 환불, buyer 환불 |
| `STATE_DEADLINE_REFUNDED` | 6000 | deadline 만료 환불 |

---

## 6. QnAEscrow와의 핵심 차이점

| 항목 | MarketplaceEscrow | QnAEscrow |
|---|---|---|
| 구매자 확인 함수 | `confirmClass()` | `acceptAnswer()` |
| 취소/환불 | `cancelClass()` (buyer 또는 trainer) | `deleteQuestion()` (asker만, 답변 없을 때) |
| 수신자 결정 | 서버 서명 시 `trainer` 지정 | `acceptAnswer` 시 asker가 선택 |
| hash 검증 | 없음 (class ID 기반) | `questionHash`, `contentHash` 검증 |
| deadline 후 제한 | `confirmClass` 차단 | `acceptAnswer` 허용 (asker 의사결정 보호) |
| claimExpiredRefund | 누구나 호출 가능 | 답변 있으면 asker만 (MEV 방어) |

---

## 7. 전체 에러 코드

| 에러 | 원인 | 대응 |
|---|---|---|
| `InvalidAddress` | token 또는 trainer가 zero address | 입력값 검증 |
| `InvalidId` | orderId가 bytes32(0) | DB ID 확인 |
| `InvalidPrice` | price == 0 | 금액 검증 |
| `UnsupportedToken` | 미등록 토큰 | 지원 토큰 목록 확인 |
| `CannotBuyOwnClass` | buyer == trainer | FE에서 사전 차단 |
| `OrderAlreadyExists` | 동일 orderId 이미 존재 | orderId 중복 방지 |
| `SignatureExpired` | 서명 후 15분 초과 | BE에 재발급 요청 |
| `InvalidSignature` | 서명 위조 또는 payload 불일치 | BE에 재발급 요청 |
| `DeadlineExpired` | escrow deadline(30일) 초과 | claimExpiredRefund 안내 |
| `DeadlineNotExpired` | deadline이 아직 안 됨 | 시간 확인 |
| `AlreadySettled` | 이미 종료된 주문 | 상태 확인 |
| `OnlyBuyer` | buyer가 아닌 사람이 confirmClass | 권한 확인 |
| `OnlyBuyerOrTrainer` | 제3자가 cancelClass | 권한 확인 |
| `OnlyRelayerOrOwner` | 권한 없는 주소가 adminSettle/adminRefund | relayer 설정 확인 |
