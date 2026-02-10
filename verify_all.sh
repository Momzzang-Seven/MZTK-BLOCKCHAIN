#!/bin/bash

source .env

CHAIN_ID=11155420
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}"

NONCE_TRACKER=0x187566a1e325705C53f097012E504BC20DF65501
RECEIVER=0x91E72675C37599Cfdf6A11E6976747e1a3E865A2
PROXY=0xb5214954cC7492B0a23Ca044D16fcB381Ba1d207
BATCH_IMPL=0x8D23eD2521A8a8F7C26576171d70c06DcaC06C93

echo "🚀 Starting verification on Optimism Sepolia (V2 API)..."

echo "1. Verifying NonceTracker..."
forge verify-contract $NONCE_TRACKER src/NonceTracker.sol:NonceTracker \
    --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_API_KEY \
    --verifier-url "$VERIFIER_URL" --watch

echo "2. Verifying DefaultReceiver..."
forge verify-contract $RECEIVER src/DefaultReceiver.sol:DefaultReceiver \
    --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_API_KEY \
    --verifier-url "$VERIFIER_URL" --watch

echo "3. Verifying BatchImplementation..."
forge verify-contract $BATCH_IMPL src/BatchImplementation.sol:BatchImplementation \
    --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_API_KEY \
    --verifier-url "$VERIFIER_URL" --watch

echo "4. Verifying EIP7702Proxy..."
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $NONCE_TRACKER $RECEIVER)

forge verify-contract $PROXY src/EIP7702Proxy.sol:EIP7702Proxy \
    --chain-id $CHAIN_ID --etherscan-api-key $ETHERSCAN_API_KEY \
    --verifier-url "$VERIFIER_URL" \
    --constructor-args $CONSTRUCTOR_ARGS --watch

echo "✅ All verification tasks submitted!"