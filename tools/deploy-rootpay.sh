#!/bin/bash
set -euo pipefail

# Load environment variables from .env if it exists
if [ -f .env ]; then
  set -a          # auto-export
  source .env
  set +a
fi

: "${PRIVATE_KEY:?PRIVATE_KEY not set}"
: "${ETH_RPC_URL:?ETH_RPC_URL not set}"

CONTRACT="src/RootPay.sol:RootPay"

echo "Deploying $CONTRACT ..."

OUTPUT=$(forge create \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  "$CONTRACT"
)

echo "$OUTPUT"

# Extract deployed address
DEPLOYED_ADDRESS=$(echo "$OUTPUT" | awk '/Deployed to:/ { print $3 }')

if [ -z "$DEPLOYED_ADDRESS" ]; then
  echo "Failed to extract deployed address"
  exit 1
fi

# Sanity check 
echo "Sanity-checking deployed bytecode..."

[ "$(cast code "$DEPLOYED_ADDRESS")" = "$(forge inspect "$CONTRACT" deployedBytecode)" ] || {
  echo "On-chain bytecode does not match local build"
  exit 1
}

for verifier in sourcify blockscout; do
  EXTRA_ARGS=()

  if [ "$verifier" = "blockscout" ]; then
    EXTRA_ARGS+=(--verifier-url https://filecoin-testnet.blockscout.com/api)
  fi

  echo "Verifying with $verifier..."

  if ! forge verify-contract \
    "$DEPLOYED_ADDRESS" \
    "$CONTRACT" \
    --verifier "$verifier" \
     ${EXTRA_ARGS:+${EXTRA_ARGS[@]}}; then

    if [ "$verifier" = "blockscout" ]; then
      echo "Blockscout verification failed (continuing)"
    else
      echo "Sourcify verification failed"
      exit 1
    fi
  fi
done


echo "Verification submitted for $DEPLOYED_ADDRESS"