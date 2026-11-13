#!/usr/bin/env bash
# End-to-end proof runner — LOCAL EPHEMERAL ONLY.
#
# Spins up a throwaway in-memory anvil on 127.0.0.1, deploys the real contracts,
# and drives submission -> grade -> signed attestation -> finalize -> settle,
# asserting the winner got paid on-chain. Tears anvil down on exit.
#
# NOTHING here connects to a public RPC / Robinhood Chain / any real network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRADER_DIR="$(cd "$HERE/.." && pwd)"
CONTRACTS_DIR="$(cd "$GRADER_DIR/../contracts" && pwd)"

RPC_URL="http://127.0.0.1:8545"

# anvil account [9] = grader signer. Key lives ONLY in this runner's env, passed
# to the grader service via GRADER_PRIVATE_KEY (never hardcoded in src/).
export GRADER_PRIVATE_KEY="0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"
export GRADER_SIGNER="0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"
# anvil account [0] (genesis TICKET holder) broadcasts the deploy
DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "== 1/4 starting LOCAL EPHEMERAL anvil (127.0.0.1:8545, in-memory) =="
anvil --silent --host 127.0.0.1 --port 8545 &
ANVIL_PID=$!

# wait for RPC to come up
for i in $(seq 1 50); do
  if cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
echo "   anvil up (pid $ANVIL_PID), chainId $(cast chain-id --rpc-url "$RPC_URL")"

echo "== 2/4 deploying contracts (forge script, local broadcast) =="
( cd "$CONTRACTS_DIR" && forge script script/DeployLocal.s.sol:DeployLocal \
    --rpc-url "$RPC_URL" --broadcast --private-key "$DEPLOYER_PK" \
    >/tmp/deploy.log 2>&1 ) || { echo "deploy failed"; tail -30 /tmp/deploy.log; exit 1; }
grep -E "TICKET|PAYOUT|BOARD|TREASURY|GRADER_SIGNER" /tmp/deploy.log | sed 's/^/   /'

echo "== 3/4 running grader end-to-end (submission -> grade -> attestation -> pay) =="
( cd "$GRADER_DIR" && RPC_URL="$RPC_URL" node proof/e2e.mjs )

echo "== 4/4 done — tearing down ephemeral anvil =="
