#!/usr/bin/env bash
# =============================================================================
# ExecuteTimelock.sh — Execute the timelock acceptOwnership for RWAVault
#
# The timelock acceptOwnership was scheduled on 2026-03-23 and becomes
# executable ~2026-03-25 13:35 UTC (48hr delay).
#
# Prerequisites:
#   - .env with PRIVATE_KEY and BASE_MAINNET_RPC
#   - .env.deploy with TIMELOCK_ADDRESS and VAULT_ADDRESS
#   - Foundry (cast) installed
# =============================================================================

set -euo pipefail

# Load environment
source .env
source .env.deploy

# Timelock parameters (zero bytes32 for no predecessor/salt)
ZERO_BYTES32=$(printf '0x%064d' 0)

echo "=== Timelock acceptOwnership Execution ==="
echo ""
echo "Vault:    $VAULT_ADDRESS"
echo "Timelock: $TIMELOCK_ADDRESS"
echo ""

# Check if the operation is ready (past the 48hr delay)
echo "--- Checking if operation is ready ---"
CALLDATA=$(cast calldata "acceptOwnership()")
OP_HASH=$(cast keccak "$(cast abi-encode \
  "encode(address,uint256,bytes,bytes32,bytes32)" \
  "$VAULT_ADDRESS" \
  0 \
  "$CALLDATA" \
  $ZERO_BYTES32 \
  $ZERO_BYTES32)")

IS_READY=$(cast call "$TIMELOCK_ADDRESS" "isOperationReady(bytes32)(bool)" "$OP_HASH" --rpc-url "$BASE_MAINNET_RPC" 2>/dev/null || echo "check_failed")

if [ "$IS_READY" = "false" ]; then
  echo "ERROR: Operation is NOT ready yet. The 48hr delay has not passed."
  echo "Try again after ~2026-03-25 13:35 UTC."

  TIMESTAMP=$(cast call "$TIMELOCK_ADDRESS" "getTimestamp(bytes32)(uint256)" "$OP_HASH" --rpc-url "$BASE_MAINNET_RPC" 2>/dev/null || echo "unknown")
  echo "Scheduled execution timestamp: $TIMESTAMP"
  exit 1
fi

echo "Operation is ready. Proceeding with execution..."
echo ""

# Current owner (should be deployer, with timelock as pendingOwner)
echo "--- Pre-execution state ---"
CURRENT_OWNER=$(cast call "$VAULT_ADDRESS" "owner()(address)" --rpc-url "$BASE_MAINNET_RPC")
echo "Current vault owner: $CURRENT_OWNER"
echo ""

# Execute
echo "--- Executing timelock acceptOwnership ---"
cast send "$TIMELOCK_ADDRESS" \
  "execute(address,uint256,bytes,bytes32,bytes32)" \
  "$VAULT_ADDRESS" \
  0 \
  "$CALLDATA" \
  $ZERO_BYTES32 \
  $ZERO_BYTES32 \
  --rpc-url "$BASE_MAINNET_RPC" \
  --private-key "$PRIVATE_KEY"

echo ""
echo "--- Post-execution verification ---"
NEW_OWNER=$(cast call "$VAULT_ADDRESS" "owner()(address)" --rpc-url "$BASE_MAINNET_RPC")
echo "New vault owner: $NEW_OWNER"

if [ "$(echo "$NEW_OWNER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$TIMELOCK_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  echo ""
  echo "SUCCESS: Vault ownership transferred to timelock!"
else
  echo ""
  echo "WARNING: Owner is $NEW_OWNER, expected $TIMELOCK_ADDRESS"
  echo "Check the transaction on Basescan for details."
  exit 1
fi
