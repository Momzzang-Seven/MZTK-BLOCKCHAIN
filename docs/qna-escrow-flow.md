# QnAEscrow — 개발자 연동 가이드

> **대상**: MZTK-BE (Spring/Java), MZTK-FE (TypeScript/ethers.js)  
> **컨트랙트**: `src/QnAEscrow.sol`  
> **네트워크**: Optimism Sepolia (chainId: 11155420), Base Sepolia (chainId: 84532)

---

## 1. 전체 흐름 한눈에 보기

```
[사용자 - FE]          [백엔드 - BE]              [컨트랙트 - QnAEscrow]
      │                     │                              │
      │ 1. 질문 작성 요청   │                              │
      │────────────────────►│                              │
      │                     │ 2. whitelist 검증            │
      │                     │    EIP-712 서명 생성         │
      │◄────────────────────│                              │
      │ 3. payload 수신     │                              │
      │    (signedAt, sig)  │                              │
      │                     │                              │
      │ 4. 지갑 서명 후 tx 전송                            │
      │────────────────────────────────────────────────────►
      │                     │                              │ 5. 검증 & 토큰 잠금
      │                     │◄─────────────────────────────│
      │                     │ 6. QuestionCreated 이벤트 수신│
      │                     │    DB 상태 업데이트           │
      │◄────────────────────│                              │
      │ 7. 완료 응답        │                              │
```

---

## 2. 백엔드 구현 (Spring / Java)

### 2-1. 상수 정의

```java
// TypeHash — 컨트랙트의 _CREATE_QUESTION_TYPEHASH와 정확히 일치해야 함
private static final String TYPE_STRING =
    "CreateQuestion(address creator,bytes32 questionId,address token," +
    "uint256 rewardAmount,bytes32 questionHash,uint256 signedAt)";

private static final byte[] CREATE_QUESTION_TYPEHASH =
    Hash.sha3(TYPE_STRING.getBytes(StandardCharsets.UTF_8));

// 도메인 세퍼레이터 구성 요소
private static final String DOMAIN_NAME    = "QnAEscrow";
private static final String DOMAIN_VERSION = "1";
```

### 2-2. EIP-712 서명 생성 (전체 코드)

```java
public byte[] signCreateQuestion(
    String  creatorAddress,   // 질문 작성자 지갑 주소
    long    dbQuestionId,     // DB의 질문 ID (int)
    String  tokenAddress,     // MZTK 토큰 주소
    BigInteger rewardAmount,  // wei 단위
    byte[]  questionHash,     // keccak256(질문 내용)
    ECKeyPair serverKeyPair   // 서버 private key
) {
    // 1. signedAt = 현재 시각 (서버가 만료시각을 정하는 게 아님)
    BigInteger signedAt = BigInteger.valueOf(Instant.now().getEpochSecond());

    // 2. DB int → bytes32 패딩
    byte[] questionIdBytes = Numeric.toBytesPadded(BigInteger.valueOf(dbQuestionId), 32);

    // 3. 구조체 해시
    byte[] structHash = Hash.sha3(
        encodePacked(
            CREATE_QUESTION_TYPEHASH,           // bytes32
            Numeric.hexStringToByteArray(creatorAddress), // address → 32byte 패딩
            questionIdBytes,                    // bytes32
            Numeric.hexStringToByteArray(tokenAddress),   // address → 32byte 패딩
            Numeric.toBytesPadded(rewardAmount, 32),      // uint256
            questionHash,                       // bytes32
            Numeric.toBytesPadded(signedAt, 32) // uint256
        )
    );

    // 4. 도메인 세퍼레이터
    byte[] domainSeparator = buildDomainSeparator(contractAddress, chainId);

    // 5. 최종 digest
    byte[] digest = Hash.sha3(
        concat(new byte[]{0x19, 0x01}, domainSeparator, structHash)
    );

    // 6. 서명 (v, r, s)
    Sign.SignatureData sig = Sign.signMessage(digest, serverKeyPair, false);

    // 7. ABI 인코딩: r + s + v (65 bytes)
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
  "questionId": "0x0000000000000000000000000000000000000000000000000000000000000001",
  "tokenAddress": "0xMZTK_TOKEN_ADDRESS",
  "rewardAmount": "100000000000000000000",
  "questionHash": "0xabc123...",
  "signedAt": 1714567890,
  "serverSig": "0xaabbcc...65bytes"
}
```

### 2-5. Receipt 기반 DB 상태 동기화

FE가 트랜잭션을 전송한 후 `txHash`를 BE에 전달하면,  
BE는 receipt를 조회해서 성공 여부와 이벤트를 파싱합니다.

#### 흐름

```
FE: tx 전송 → txHash 획득
FE → BE: POST /api/questions/confirm { txHash }
BE: eth_getTransactionReceipt(txHash) 조회
BE: receipt.status 확인 + logs에서 이벤트 파싱
BE: DB 업데이트 후 응답
```

#### Java / Web3j 구현

```java
public QuestionConfirmResult confirmByReceipt(String txHash) throws Exception {

    // 1. receipt 조회 (아직 마이닝 중이면 empty → polling 필요)
    Optional<TransactionReceipt> opt = web3j
        .ethGetTransactionReceipt(txHash)
        .send()
        .getTransactionReceipt();

    if (opt.isEmpty()) {
        // 아직 pending — 재시도 로직 (예: 최대 10초, 1초 간격)
        throw new TransactionPendingException("Transaction not yet mined: " + txHash);
    }

    TransactionReceipt receipt = opt.get();

    // 2. 실패 tx 차단 (status == "0x0" → revert됨)
    if (!receipt.isStatusOK()) {
        throw new TransactionFailedException("Transaction reverted: " + txHash);
    }

    // 3. QuestionCreated 이벤트 파싱
    List<QnAEscrow.QuestionCreatedEventResponse> events =
        qnaEscrowContract.getQuestionCreatedEvents(receipt);

    if (events.isEmpty()) {
        throw new EventNotFoundException("QuestionCreated event not found in receipt");
    }

    QuestionCreatedEventResponse event = events.get(0);

    // 4. DB 업데이트
    long questionId = event.questionId.toBigInteger().longValue(); // bytes32 → long
    questionRepository.updateStatus(questionId, "ESCROWED");
    questionRepository.updateDeadline(questionId, event... ); // 필요 시 onchain 조회

    return new QuestionConfirmResult(questionId, txHash);
}
```

#### Polling 유틸리티 (pending tx 대기)

```java
public TransactionReceipt waitForReceipt(String txHash, int maxRetry, long intervalMs)
        throws Exception {
    for (int i = 0; i < maxRetry; i++) {
        Optional<TransactionReceipt> opt = web3j
            .ethGetTransactionReceipt(txHash)
            .send()
            .getTransactionReceipt();

        if (opt.isPresent()) return opt.get();

        Thread.sleep(intervalMs);
    }
    throw new TimeoutException("Receipt not found after " + maxRetry + " retries: " + txHash);
}

// 사용 예: 최대 30초 대기 (3초 × 10회)
TransactionReceipt receipt = waitForReceipt(txHash, 10, 3000);
```

#### 함수별 파싱 이벤트 & DB 매핑

| 호출 함수 | receipt에서 파싱할 이벤트 | DB 업데이트 |
|---|---|---|
| `createQuestion` | `QuestionCreated` | status = `ESCROWED` |
| `submitAnswer` | `AnswerSubmitted` | status = `ANSWERED` |
| `acceptAnswer` | `AnswerAccepted` | status = `PAID_OUT` |
| `deleteQuestion` | `QuestionDeleted` | status = `DELETED` |
| `adminSettle` | `AdminSettled` | status = `ADMIN_SETTLED` |
| `adminRefund` | `AdminRefunded` | status = `DELETED` |
| `claimExpiredRefund` | `DeadlineRefunded` | status = `DEADLINE_REFUNDED` |



---

## 3. 프론트엔드 구현 (TypeScript / ethers.js v6)

### 3-1. 서버에서 payload 수신 후 approve + createQuestion 호출

#### EIP-1559 경로 (사용자가 직접 가스 지불)

```typescript
import { ethers } from "ethers";

async function createQuestion(payload: {
  questionId: string;    // bytes32 hex string
  tokenAddress: string;
  rewardAmount: bigint;
  questionHash: string;  // bytes32 hex string
  signedAt: number;
  serverSig: string;     // 65-byte hex string
}) {
  const signer = await provider.getSigner();

  // 1. ERC20 approve
  const token = new ethers.Contract(payload.tokenAddress, ERC20_ABI, signer);
  const approveTx = await token.approve(QNA_ESCROW_ADDRESS, payload.rewardAmount);
  await approveTx.wait();

  // 2. createQuestion 호출
  const escrow = new ethers.Contract(QNA_ESCROW_ADDRESS, QNA_ESCROW_ABI, signer);
  const tx = await escrow.createQuestion(
    payload.questionId,
    payload.tokenAddress,
    payload.rewardAmount,
    payload.questionHash,
    payload.signedAt,
    payload.serverSig
  );

  const receipt = await tx.wait();

  // 3. 성공 확인
  if (receipt.status === 1) {
    console.log("질문 생성 성공:", tx.hash);
    // QuestionCreated 이벤트 파싱
    const event = receipt.logs
      .map(log => escrow.interface.parseLog(log))
      .find(e => e?.name === "QuestionCreated");
    console.log("질문 ID:", event?.args.questionId);
  }
}
```

#### EIP-7702 경로 (가스 대납 / 배치 트랜잭션)

```typescript
async function createQuestionBatch(payload: typeof createQuestion.arguments[0]) {
  // BatchImplementation.execute(calls, sig) 사용
  const calls = [
    {
      to: payload.tokenAddress,
      value: 0n,
      data: ERC20_IFACE.encodeFunctionData("approve", [
        QNA_ESCROW_ADDRESS,
        payload.rewardAmount
      ])
    },
    {
      to: QNA_ESCROW_ADDRESS,
      value: 0n,
      data: QNA_ESCROW_IFACE.encodeFunctionData("createQuestion", [
        payload.questionId,
        payload.tokenAddress,
        payload.rewardAmount,
        payload.questionHash,
        payload.signedAt,
        payload.serverSig
      ])
    }
  ];

  // 사용자가 배치 서명
  const batchSig = await signBatch(calls, userAddress, batchNonce);
  // 서버(relayer)가 execute 호출
  await relayerCall("execute", [calls, batchSig]);
}
```

### 3-2. 에러 처리

```typescript
try {
  const tx = await escrow.createQuestion(...);
} catch (err: any) {
  const errorName = escrow.interface.parseError(err.data)?.name;
  switch (errorName) {
    case "SignatureExpired":
      // 서버에 서명 재발급 요청
      await refreshServerSignature();
      break;
    case "InvalidSignature":
      // 서명 오류 → 서버에 재발급 요청
      await refreshServerSignature();
      break;
    case "QuestionAlreadyExists":
      // 동일 questionId로 이미 생성됨
      showError("이미 등록된 질문입니다.");
      break;
    case "UnsupportedToken":
      showError("지원하지 않는 토큰입니다.");
      break;
    case "DeadlineExpired":
      showError("질문 기한이 만료되었습니다.");
      break;
    default:
      showError("트랜잭션 실패: " + errorName);
  }
}
```

### 3-3. 답변 수락 (acceptAnswer)

```typescript
async function acceptAnswer(
  questionId: string,  // bytes32
  answerId: string,    // bytes32
  questionHash: string, // bytes32 — 현재 온체인 저장된 값과 일치해야 함
  contentHash: string   // bytes32 — 답변의 contentHash
) {
  const escrow = new ethers.Contract(QNA_ESCROW_ADDRESS, QNA_ESCROW_ABI, signer);
  // 해시 불일치 시 HashMismatch revert → DB의 해시와 온체인 해시를 항상 맞게 유지
  const tx = await escrow.acceptAnswer(questionId, answerId, questionHash, contentHash);
  await tx.wait();
}
```

---

## 4. 컨트랙트 함수 전체 참조

### createQuestion

```solidity
function createQuestion(
    bytes32 questionId,   // DB int를 bytes32로 left-pad (abi.encode 방식)
    address token,        // MZTK 주소
    uint256 rewardAmount, // wei 단위
    bytes32 questionHash, // keccak256(질문 원문)
    uint256 signedAt,     // 서버 서명 시각 (unix timestamp, seconds)
    bytes calldata signature // 서버 EIP-712 서명 (65 bytes: r+s+v)
) external
```

**검증 순서 & 에러:**

| 순서 | 조건 | 에러 |
|---|---|---|
| 1 | `token != address(0)` | `InvalidAddress` |
| 2 | `questionId != bytes32(0)` | `InvalidId` |
| 3 | `isSupportedToken[token]` | `UnsupportedToken` |
| 4 | `rewardAmount > 0` | `InvalidRewardAmount` |
| 5 | 중복 questionId 없음 | `QuestionAlreadyExists` |
| 6 | `questionHash != bytes32(0)` | `InvalidContentHash` |
| 7a | `signedAt <= block.timestamp` | `InvalidSignature` |
| 7b | `block.timestamp <= signedAt + 15분` | `SignatureExpired` |
| 8 | 서명 복원 주소 == signer | `InvalidSignature` |

### 그 외 주요 함수

```solidity
// 답변 제출 (deadline 이전만 가능)
submitAnswer(bytes32 questionId, bytes32 answerId, bytes32 contentHash)

// 답변 수락 → 보상 지급
acceptAnswer(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash)

// 질문 삭제 + 환불 (답변 없을 때만)
deleteQuestion(bytes32 questionId)

// 관리자 정산 (deadline 이전만)
adminSettle(bytes32 questionId, bytes32 answerId, bytes32 questionHash, bytes32 contentHash)

// 관리자 환불
adminRefund(bytes32 questionId)

// 비상 탈출 — deadline 이후 누구나 호출 가능
// 단, 답변 있으면 asker만 호출 가능 (MEV 방어)
claimExpiredRefund(bytes32 questionId)
```

---

## 5. 상태 머신

```
createQuestion()
      │
      ▼
  CREATED (1000) ──── submitAnswer() [deadline 이전만] ──► ANSWERED (1100)
      │                       │                                    │
      │               deleteAnswer()                        acceptAnswer()
      │          (모든 답변 삭제 시 → CREATED 복귀)                │
      │                                                            ▼
      │                                                      PAID_OUT (2100)
      │
      ├─ deleteQuestion()  → DELETED (5000)         [답변 0개일 때, asker만]
      ├─ adminSettle()     → ADMIN_SETTLED (4000)   [deadline 이전, relayer/owner]
      ├─ adminRefund()     → DELETED (5000)          [relayer/owner]
      │                      또는 DELETED_WITH_ANSWERS (5100)
      └─ claimExpiredRefund() → DEADLINE_REFUNDED (6000)  [deadline 이후]
           답변 없음: 누구나 가능
           답변 있음: asker만 가능 (acceptAnswer 보호)
```

**상태 코드 상수:**

| 상수명 | 값 | 의미 |
|---|---|---|
| `STATE_CREATED` | 1000 | 질문 등록됨, 토큰 잠금 |
| `STATE_ANSWERED` | 1100 | 답변 1개 이상 존재 |
| `STATE_PAID_OUT` | 2100 | 답변 수락 완료, 보상 지급됨 |
| `STATE_ADMIN_SETTLED` | 4000 | 관리자가 정산 |
| `STATE_DELETED` | 5000 | 삭제 (환불 완료) |
| `STATE_DELETED_WITH_ANSWERS` | 5100 | 답변 있는 상태로 삭제 |
| `STATE_DEADLINE_REFUNDED` | 6000 | deadline 초과 환불 |

---

## 6. 핵심 개념 정리

### signedAt vs deadline

| 필드 | 타입 | 위치 | 역할 |
|---|---|---|---|
| `signedAt` | `uint256` | 함수 파라미터 | 서버 서명 시각. 서버는 `now`를 넣고, 컨트랙트가 **15분** 유효 창으로 검증 |
| `deadline` | `uint48` | Question struct | 에스크로 만료. 생성 시 `now + 30일` 자동 세팅. `claimExpiredRefund` 트리거 |

### questionId 인코딩

DB의 int ID를 bytes32로 변환할 때 **ABI 인코딩(zero left-pad)**을 사용합니다.

```java
// Java
byte[] questionIdBytes = Numeric.toBytesPadded(BigInteger.valueOf(dbId), 32);
```

```typescript
// TypeScript
const questionId = ethers.zeroPadValue(ethers.toBeHex(dbId), 32);
```

### questionHash 계산

```java
// Java — 질문 원문을 UTF-8로 해시
byte[] questionHash = Hash.sha3(questionContent.getBytes(StandardCharsets.UTF_8));
```

```typescript
// TypeScript
const questionHash = ethers.keccak256(ethers.toUtf8Bytes(questionContent));
```

### replay protection 구조

`questionId`가 서명 payload에 포함되고, 컨트랙트가 동일 ID의 중복 생성을 차단하므로 per-user nonce 없이도 replay protection이 보장됩니다.

```
- questionId/orderId는 DB auto-increment → 전역 유일
- 서명 payload에 questionId 포함 → ID가 다르면 서명도 다름
- 컨트랙트: QuestionAlreadyExists revert → 한 번 성공하면 재사용 불가
- signedAt + sigValidityDuration(15분)으로 서명 유효기간 제한
- EIP-712 domain에 chainId + verifyingContract → 크로스체인 재사용 불가
```

---

## 7. 전체 에러 코드

| 에러 | 원인 | 대응 |
|---|---|---|
| `InvalidAddress` | token 또는 주소가 zero | 입력값 검증 |
| `InvalidId` | questionId 또는 answerId가 zero | DB ID 확인 |
| `InvalidContentHash` | hash가 zero | 내용 검증 |
| `InvalidRewardAmount` | rewardAmount == 0 | 금액 검증 |
| `UnsupportedToken` | 미등록 토큰 | 지원 토큰 목록 확인 |
| `QuestionAlreadyExists` | 동일 ID로 이미 생성됨 | questionId 중복 방지 |
| `SignatureExpired` | 서명 후 15분 초과 | BE에 재발급 요청 |
| `InvalidSignature` | 서명 위조 또는 payload 불일치 | BE에 재발급 요청 |
| `DeadlineExpired` | escrow deadline(30일) 초과 | claimExpiredRefund 안내 |
| `DeadlineNotExpired` | deadline이 아직 안 됨 | 시간 확인 |
| `QuestionAlreadyResolved` | 이미 종료된 질문 | 상태 확인 |
| `HashMismatch` | questionHash 또는 contentHash 불일치 | DB와 온체인 해시 동기화 |
| `CannotAnswerOwnQuestion` | 질문자가 자기 답변 | FE 차단 |
| `OnlyAskerCanAccept` | 질문자가 아닌 사람이 acceptAnswer | 권한 확인 |
| `OnlyAsker` | 질문자가 아닌 사람이 deleteQuestion/updateQuestion | 권한 확인 |
| `AnswerAlreadyExists` | 동일 answerId 중복 | answerId 중복 방지 |
| `AnswerNotFound` | 존재하지 않는 answerId | DB 동기화 확인 |
