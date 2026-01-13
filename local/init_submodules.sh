#!/usr/bin/env bash
set -euo pipefail

# Init the FYVEVM submodule without recursing into its own submodules to avoid
# the circular FlowYieldVaults ↔ FlowYieldVaultsEVM chain. Then init the rest.

git submodule update --init lib/FlowYieldVaultsEVM

git -C lib/FlowYieldVaultsEVM config submodule.lib/FlowYieldVaults.update none
git -C lib/FlowYieldVaultsEVM config submodule.solidity/lib/forge-std.update none
git -C lib/FlowYieldVaultsEVM config submodule.solidity/lib/openzeppelin-contracts.update none

git submodule update --init --recursive
