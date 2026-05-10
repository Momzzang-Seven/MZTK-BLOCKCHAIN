## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Deployed Contracts

### Optimism Sepolia (Chain ID: 11155420)

| Contract | Address |
| :--- | :--- |
| **MZTK Token** | `0x815B53fD2D56044BaC39c1f7a9C7d3E67322f0F5` |
| **MarketplaceEscrow** | `0x872070a70b291caC3Dc65DaA50670b22dcf739Ff` |
| **QnAEscrow** | `0xbd735bD909F26034587CC209e338f30a05aed561` |
| **NonceTracker** | `0x187566a1e325705C53f097012E504BC20DF65501` |
| **DefaultReceiver** | `0x91E72675C37599Cfdf6A11E6976747e1a3E865A2` |
| **EIP7702Proxy** | `0xb5214954cC7492B0a23Ca044D16fcB381Ba1d207` |
| **BatchImplementation** | `0x8D23eD2521A8a8F7C26576171d70c06DcaC06C93` |

### Base Sepolia (Chain ID: 84532)

| Contract | Address |
| :--- | :--- |
| **MZTK Token** | `0xfd6c0dc7fbe6a200d53d00bbaa2a276d02865de8` |
| **MarketplaceEscrow** | `0x2955e5239077B8C1010F6F670152DA11F0b487d0` |
| **QnAEscrow** | `0x394f5212bb44821DDfCe6D618913CEf588482dAD` |
| **NonceTracker** | `0x947Ba6E8994B070113318E50aBb42636Db79A3Ab` |
| **DefaultReceiver** | `0x858C82363e7562ec1845e6BcFa1C0355F039Dac3` |
| **EIP7702Proxy** | `0xD31dD102AD94e992715078F7ce2d51d9d7081c73` |
| **BatchImplementation** | `0xB550530762b3634C7beF21a1e376AeDd3A6eAdB4` |

## EVM Version

- **Target Version:** `cancun` (Default for current deployments)
- **Upcoming Compatibility:**
    - Prague (Expected 2025.05)
    - Osaka (Latest)
- **Reference:** [Blockscout EVM Version Info](https://docs.blockscout.com/setup/information-and-settings/evm-version-information)

---

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
# 특정 파일만
$ forge test --match-path test/파일명.t.sol
# 특정 컨트랙트만
forge test --match-contract 컨트랙트명 
# 특정 테스트 함수만
forge test --match-test test_이름 (예: forge test --match-test test_PurchaseClassWithSig
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
