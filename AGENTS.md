# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, Cursor, Copilot, and others)
when working in this repository. It is loaded into agent context automatically — keep it concise.

## Overview

FlowYieldVaults is a Cadence yield-farming platform on Flow (`README.md`). It orchestrates yield-generating strategies (`TracerStrategy`, `FUSDEVStrategy`, `PMStrategiesV1`) composed from DeFi Actions connectors, with an AutoBalancer that rebalances positions against configured thresholds and a scheduled-rebalancing system built on `FlowTransactionScheduler`. Main contract addresses per `flow.json`: mainnet `0xb1d63873c3cc9f79`, testnet `0xd2580caf2ef07c2f`. The repo also contains Solidity sources and three git submodules in `lib/` (`FlowALP`, `flow-evm-bridge`, `flow-evm-gateway`) plus Solidity submodules under `solidity/lib/` (OpenZeppelin, forge-std, Uniswap v2, PunchSwap v3).

## Setup

- `git submodule update --init --recursive` — pulls `lib/FlowALP`, `lib/flow-evm-bridge`, `lib/flow-evm-gateway`, and Solidity libs under `solidity/lib/` (`.gitmodules`)
- `flow deps install --skip-alias --skip-deployments` — installs Cadence deps (used by `local/setup_emulator.sh` and every CI workflow)

## Build and Test Commands

- `flow test ./cadence/tests/*_test.cdc` — run the full Cadence test suite (33 `*_test.cdc` files under `cadence/tests/`)
- `flow test --cover --covercode="contracts" --coverprofile="coverage.lcov" ./cadence/tests/*_test.cdc` — CI coverage run (`.github/workflows/cadence_tests.yml`)
- `./run_all_precision_tests.sh` — runs `rebalance_scenario{1,2,3a-d}_test.cdc` and prints precision diffs
- Local bring-up sequence: `./local/run_emulator.sh` → `./local/setup_wallets.sh` → `./local/run_evm_gateway.sh` → `./local/setup_emulator.sh` (order mirrors `.github/workflows/e2e_tests.yml`)
- `./local/e2e_test.sh` — end-to-end user-flow test (run after local bring-up)
- `./local/punchswap/setup_punchswap.sh` + `./local/punchswap/e2e_punchswap.sh` — deploy KittyPunch/PunchSwap V3 via Foundry
- `./local/incrementfi/setup_incrementfi.sh` — deploy IncrementFi swap contracts into emulator
- `forge` — Solidity toolchain per `foundry.toml` (src `./solidity/src`, tests `./solidity/test`, libs `./solidity/lib`)
- `docker build .` — reproduces the full seeded emulator + EVM gateway image (`Dockerfile`)

## Architecture

In-repo Cadence contracts (`cadence/contracts/*.cdc`, 8 files):

- `FlowYieldVaults.cdc` — main platform contract (`YieldVault` / `YieldVaultManager` resources, strategy composition)
- `FlowYieldVaultsAutoBalancers.cdc` — AutoBalancer instances; threshold-driven rebalancing
- `FlowYieldVaultsStrategiesV2.cdc` — `FUSDEVStrategy`, `MorphoERC4626StrategyComposer`; deploy args are three EVM addresses (`flow.json` `deployments`)
- `PMStrategiesV1.cdc` — PM strategy family; covered by `PMStrategiesV1_{deferred_redeem,FUSDEV,syWFLOWv}_test.cdc`
- `FlowYieldVaultsSchedulerRegistry.cdc` + `FlowYieldVaultsSchedulerV1.cdc` — scheduled rebalancing on `FlowTransactionScheduler`
- `FlowYieldVaultsClosedBeta.cdc` — beta-access gating (`grant_beta`, `issue_beta`, `revoke_beta` in `cadence/transactions/flow-yield-vaults/admin/`)
- `UInt64LinkedList.cdc` — util used by the scheduler registry

In-repo mocks tree (`cadence/contracts/mocks/`, full listing):

- `EVM.cdc` — emulator EVM mock (aliased as `MockEVM` in `flow.json`)
- `FlowTransactionScheduler.cdc` — emulator scheduler mock (aliased as `MockFlowTransactionScheduler`)
- `FlowYieldVaultsClosedBeta_validate_beta_false.cdc` — alternate `FlowYieldVaultsClosedBeta` compiled with beta validation off (test-only drop-in)
- `MockFlowALPConsumer.cdc` — test consumer for FlowALP integrations
- `MockOracle.cdc`, `MockSwapper.cdc`, `MockStrategies.cdc` (contains `TracerStrategy`), `MockStrategy.cdc`, `YieldToken.cdc`
- `incrementfi/SwapPairTemplate.cdc` — IncrementFi swap-pair template for emulator deployment

External Cadence deps (sourced from `lib/FlowALP/…`, listed under `flow.json` `contracts`): `AdversarialReentrancyConnectors`, `AdversarialTypeSpoofingConnectors`, `BandOracleConnectors`, `DeFiActions`, `DeFiActionsUtils`, `DummyConnectors`, `ERC4626PriceOracles`, `ERC4626SinkConnectors`, `ERC4626SwapConnectors`, `ERC4626Utils`, `EVMAbiHelpers`, `EVMAmountUtils`, `EVMTokenConnectors`, `FlowALPMath`, `FlowALPv0`, `FungibleTokenConnectors`, `MOET`, `MockDexSwapper`, `MorphoERC4626SinkConnectors`, `MorphoERC4626SwapConnectors`, `SwapConnectors`, `UniswapV3SwapConnectors`.

External mainnet-aliased deps (`flow.json` `dependencies`, fetched by `flow deps install`): `ArrayUtils`, `BandOracle`, `Burner`, `CrossVMMetadataViews`, `CrossVMNFT`, `CrossVMToken`, `EVM`, `FlowEVMBridge`, `FlowEVMBridgeAccessor`, `FlowEVMBridgeConfig`, `FlowEVMBridgeCustomAssociationTypes`, `FlowEVMBridgeCustomAssociations`, `FlowEVMBridgeHandlerInterfaces`, `FlowEVMBridgeHandlers`, `FlowEVMBridgeNFTEscrow`, `FlowEVMBridgeResolver`, `FlowEVMBridgeTemplates`, `FlowEVMBridgeTokenEscrow`, `FlowEVMBridgeUtils`, `FlowFees`, `FlowStorageFees`, `FlowToken`, `FlowTransactionScheduler`, `FlowTransactionSchedulerUtils`, `FungibleToken`, `FungibleTokenMetadataViews`, `IBridgePermissions`, `ICrossVM`, `ICrossVMAsset`, `IEVMBridgeNFTMinter`, `IEVMBridgeTokenMinter`, `IFlowEVMNFTBridge`, `IFlowEVMTokenBridge`, `MetadataViews`, `NonFungibleToken`, `ScopedFTProviders`, `Serialize`, `SerializeMetadata`, `StableSwapFactory`, `StringUtils`, `SwapConfig`, `SwapError`, `SwapFactory`, `SwapInterfaces`, `SwapRouter`, `USDCFlow`, `ViewResolver`.

Solidity side: `solidity/src/tokens/USDC6.sol`, `solidity/src/tokens/WBTC8.sol`; submodules in `solidity/lib/`.

Tx/script layout: `cadence/transactions/flow-yield-vaults/` for user ops (`create_yield_vault`, `deposit_to_yield_vault`, `withdraw_from_yield_vault`, `close_yield_vault`, `setup`) and `.../admin/` for 22 admin txs including `rebalance_auto_balancer_by_id`, `schedule_supervisor`, `upsert_strategy_config`, `upsert-pm-strategy-config`. Scripts mirror under `cadence/scripts/flow-yield-vaults/` (views, balances, scheduler status, beta metrics).

## Conventions and Gotchas

- Versioning (`CONTRACT_VERSIONING.md`): `main` is dev-only and never deployed; mainnet is deployed from a version branch (currently `v0`). Non-upgradable changes (storage/resource layout) require a new version branch and suffixed contract names (`V1`, `V2`). Contract names must remain stable within a version.
- From `.cursor/rules/standards.mdc`: no emojis; all `.md` except `README.md` belong in `docs/`; never lower test expectations to match buggy behavior — fix the implementation instead; run all tests locally before pushing.
- `flow.json` `testing` aliases: `FlowYieldVaults*` and `PMStrategiesV1` use `0x0000000000000009`; `BandOracle*`, `DeFiActions*`, `EVMAbiHelpers`, `FlowALPMath`, `FungibleTokenConnectors`, `SwapConnectors`, `UniswapV3SwapConnectors`, `MockDexSwapper` use `0x0000000000000007`; `FlowALPv0`, `MOET`, `DummyConnectors`, `AdversarialReentrancy/TypeSpoofingConnectors` use `0x0000000000000008`; `EVMAmountUtils`, `EVMTokenConnectors`, `ERC4626*`, `Morpho*` use `0x0000000000000009`; FlowEVMBridge + standard interfaces use `0x0000000000000001`; `YieldToken` uses `0x0000000000000010`. Don't reassign these.
- Two rebalancing mechanisms coexist (`README.md`): AutoBalancer rebalancing (DFB value-ratio, thresholds `0.95`/`1.05`) and FlowALP position rebalancing (loan-health). Don't conflate them.
- Emulator deploy order matters — see `deployments.emulator.emulator-flow-yield-vaults` in `flow.json`: `UInt64LinkedList` → `FlowYieldVaultsSchedulerRegistry` → `FlowYieldVaultsAutoBalancers` → `FlowYieldVaultsSchedulerV1` → `FlowYieldVaultsClosedBeta` → `FlowYieldVaults` → `FlowYieldVaultsStrategiesV2` → `PMStrategiesV1`. Strategy contracts take EVM-address string args.
- CI (`.github/workflows/`) pins Go `1.23.x` and checks out submodules recursively across `cadence_tests.yml`, `e2e_tests.yml`, `scheduled_rebalance_tests.yml`, `incrementfi_tests.yml`, `punchswap.yml`, `build-flow-emulator.yml`. New files matching `cadence/tests/*_test.cdc` are auto-picked up by the coverage workflow; the scheduled-rebalance workflow enumerates specific files — update it when adding scheduler tests.
- Mainnet admin accounts sign via Google KMS (`flow.json` `accounts.mainnet-admin`, `mainnet-flow-alp-deployer`, `mainnet-band-oracle-connectors`, `testnet-admin`, `testnet-flow-alp-deployer`). Do not add file-key entries for mainnet signers.
- Code ownership: `@onflow/flow-defi` owns everything (`.github/CODEOWNERS`).

## Files Not to Modify

- `lib/FlowALP/`, `lib/flow-evm-bridge/`, `lib/flow-evm-gateway/` — git submodules
- `solidity/lib/` — git submodules (OpenZeppelin, forge-std, Uniswap v2, PunchSwap v3)
- `local/*.pkey` / `local/*.pubkey` — emulator dev keys
- `SEO_AUDIT_REPORT.md`, `.audit-extract.json` — generated audit artifacts
- `1-flow-yield-vaults-diagram.png`, `2-flow-yield-vaults-diagram.png`, `3-flow-yield-vaults-diagram.png` — architecture diagrams
