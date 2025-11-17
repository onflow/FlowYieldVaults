#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Starting Flow emulator with scheduled transactions for FlowALP liquidation tests..."
cd "$ROOT_DIR"

bash "./local/start_emulator_scheduled.sh"


