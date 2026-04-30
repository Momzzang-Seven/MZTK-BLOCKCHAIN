# MZTK-BLOCKCHAIN — Agent Context

This file provides essential context for AI coding assistants (Claude, Gemini, etc.)
working on the MZTK smart contract repository. Read this before making any changes.

---

## Project Overview

MZTK-BLOCKCHAIN is the on-chain layer of the **Momzzang-Seven** platform.
It contains EVM smart contracts for:

- **Escrow** — trustless class purchases (`MarketplaceEscrow`) and Q&A rewards (`QnAEscrow`)
- **EIP-7702 Account Abstraction** — proxy-based EOA upgrades (`EIP7702Proxy` + `BatchImplementation`)
- **Token** — MZTK ERC20 (`MyERC20`)

The backend (`MZTK-BE`) calls these contracts via a **relayer account** that is whitelisted
in both escrow contracts. The frontend (`MZTK-FE`) reads contract state directly via RPC.

---

## Environment

| Item | Value |
|---|---|
| Toolchain | Foundry (forge, cast, anvil) |
| Solidity | `^0.8.33` (set in `foundry.toml`) |
| EVM target | `cancun` (set in `foundry.toml`) |
| Network | Optimism Sepolia (`chainId=11155420`) |
| Deployer | Keystore account `my_deployer` (managed via `cast wallet`) |

### Install Foundry (if not present)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

---

## Essential Commands

```bash
# Compile all contracts
forge build

# Run all tests (with verbose output)
forge test -vvvv

# Run a specific test file
forge test --match-path test/MarketplaceEscrow.t.sol -vvvv

# Run a specific test function
forge test --match-test test_claimExpiredRefund -vvvv

# Format all Solidity files
forge fmt

# Gas snapshot
forge snapshot

# Local node
anvil

# Deploy (uses Makefile targets)
make deploy-token
make deploy-7702
make deploy-marketplace
make deploy-qna
```

---

## Repository Layout

```
src/
  MarketplaceEscrow.sol      # Class purchase escrow (with deadline)
  QnAEscrow.sol              # Q&A reward escrow (with deadline)
  EIP7702Proxy.sol           # EIP-7702 EOA proxy
  BatchImplementation.sol    # Batch-call implementation for EOA accounts
  NonceTracker.sol           # Replay-protection nonce store
  DefaultReceiver.sol        # ETH receiver fallback
  MyERC20.sol                # MZTK ERC20 token
  interfaces/
    IMarketplaceEscrow.sol
    IQnAEscrow.sol
    IAccountStateValidator.sol

script/                      # Forge deploy scripts (*.s.sol)
test/                        # Forge tests (*.t.sol)
docs/                        # Architecture & developer guides
broadcast/                   # Forge broadcast artifacts (gitignored in prod)
lib/                         # Forge submodule dependencies
```

---

## Key Conventions

### Solidity Style
- Use **custom errors** (`revert ErrorName()`), never `require(msg, string)`.
- All public/external functions must have an **English comment** on the line above.
- State constants follow `STATE_*` naming with `uint16` type and 4-digit values.
- `uint48` for timestamps and deadline fields (struct packing).
- Use `SafeERC20` for all token transfers.

### Contract Architecture
- Both escrow contracts follow the same pattern:
  `onlyOwner` for config → `onlyRelayerOrOwner` for lifecycle ops → `permissionless` for deadline refund
- Do **not** add upgradability (proxy patterns) to escrow contracts — they are intentionally immutable.
- Cross-contract calls should be minimal; escrows are self-contained.

### Testing
- Test files live in `test/` with the suffix `.t.sol`.
- Use `forge-std/Test.sol` as the base.
- Every new function must have at minimum: happy-path test + revert test.
- Use `vm.warp()` to test deadline-related logic.

### Deployment
- Deploy scripts live in `script/` with the suffix `.s.sol`.
- All deployments use the `COMMON_ARGS` pattern defined in `Makefile`.
- After deployment, run `verify_all.sh` to verify contracts on Etherscan.

---

## Security Invariants (do not break)

1. **Escrow balance ≥ sum of all `STATE_CREATED` order/question prices** — no function may
   transfer out more than a single order's locked amount.
2. **Terminal states are final** — once an order/question leaves `STATE_CREATED` or
   `STATE_ANSWERED`, no function may move it to another state.
3. **Deadline guard** — `confirmClass` and `adminSettle` must reject calls when
   `block.timestamp > deadline`. Only `cancelClass`, `adminRefund`, and `claimExpiredRefund`
   may execute post-deadline.
4. **No native ETH custody in escrows** — escrow contracts only hold ERC20 tokens.

---

## Related Repositories

| Repo | Role |
|---|---|
| `MZTK-BE` | Spring Boot backend / relayer |
| `MZTK-FE` | Next.js frontend |
| `MZTK-BLOCKCHAIN` | This repo — smart contracts |
