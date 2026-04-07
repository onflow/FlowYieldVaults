#!/usr/bin/env bash
# setup_mainnet_fork_docker.sh — One-shot setup for the mainnet-fork docker service.
#
# Runs after the flow-emulator-fork service is healthy. Deploys contracts and
# configures the backend-relevant state (strategies, oracle, beta access, COA funding).
#
# Usage (via docker-compose):
#   Invoked automatically by the flow-fork-setup service.
#
# Environment:
#   FLOW_HOST  — gRPC host of the running emulator (default: flow-emulator-fork:3569)

set -euo pipefail

FLOW_HOST="${FLOW_HOST:-flow-emulator-fork:3569}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./mainnet_fork_common.sh
source "$SCRIPT_DIR/mainnet_fork_common.sh"

run_setup 31536000

echo ""
echo "✅ Mainnet-fork setup complete. Backend is ready."
