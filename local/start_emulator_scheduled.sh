#!/bin/bash

set -euo pipefail

KEY=$(sed 's/^0x//' local/emulator-account.pkey | tr -d '\n')

echo "Starting Flow emulator with scheduled transactions..."
echo "Using flow"
flow emulator --scheduled-transactions --block-time 1s \
  --service-priv-key "$KEY" \
  --service-sig-algo ECDSA_P256 \
  --service-hash-algo SHA3_256


