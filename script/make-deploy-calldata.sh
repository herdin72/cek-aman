#!/usr/bin/env bash
# Builds the exact calldata for deploying CekAman through the deterministic CREATE2
# deployment proxy (0x4e59b44847b379578588920ca78fbf26c0b4956c, live on BSC).
# This lets a wallet that can only make *contract calls* (e.g. an Agentic Wallet via
# `baw contract-call`) deploy the contract: to = proxy, value = 0, inputData = salt ++ initcode.
# Read-only: prints values and writes deploy/deploy-calldata.txt. Sends nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

PROXY=0x4e59b44847b379578588920ca78fbf26c0b4956c
REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F   # SPACE ID Agent ID registry (BSC)
RPC=${RPC:-https://bsc-dataseed.bnbchain.org}
FROM=${FROM:-0x8E78ade1b0B56D7b149A4209258a7D84aeeA5EBd}

forge build -q
BC=$(jq -r .bytecode.object out/CekAman.sol/CekAman.json)
ARGS=$(cast abi-encode "constructor(address)" "$REGISTRY")
INIT="${BC}${ARGS#0x}"
SALT=$(cast keccak "cek-aman-v1")
PRED=$(cast create2 --deployer "$PROXY" --salt "$SALT" --init-code "$INIT" | awk '{print $1}' | head -1)
DATA="0x${SALT#0x}${INIT#0x}"
echo "$DATA" > deploy/deploy-calldata.txt

echo "proxy (to)        : $PROXY"
echo "constructor arg   : $REGISTRY"
echo "salt              : $SALT"
echo "predicted address : $PRED"
echo "already deployed? : $( [ "$(cast code "$PRED" --rpc-url "$RPC")" = "0x" ] && echo no || echo YES )"
echo "calldata bytes    : $(( (${#DATA} - 2) / 2 ))  (saved to deploy/deploy-calldata.txt)"
GAS=$(cast estimate --from "$FROM" "$PROXY" "$DATA" --rpc-url "$RPC")
GP=$(cast gas-price --rpc-url "$RPC")
echo "estimated gas     : $GAS"
echo "gas price (wei)   : $GP"
echo "estimated cost BNB: $(cast from-wei $((GAS * GP)))"
