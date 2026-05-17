---
title: Hello Flow Credit Markets: Create and Inspect a Position
description: Learn how to create and inspect Flow Credit Markets positions using the frontend and CLI tools
sidebar_position: 1
keywords:
  - flow credit market
  - flow yield vaults
  - yield farming
  - flow blockchain
  - cadence smart contracts
  - defi strategies
  - position management
  - flow credit market
  - moet
  - yield tokens
  - position health
---

TODO: REPLACE 0x179b6b1cb6755e31 with <YOUR_ACCOUNT_ADDRESS>

# Hello Flow Credit Markets: Create and Inspect a Position

:::warning

Flow Credit Markets (FCM) is currently in closed beta. This tutorial demonstrates the core concepts using mock contracts and the Flow emulator. The specific implementation of ALP, MOET, and FYV components may change as development progresses.

These tutorials will be updated, but you may need to refactor your code if the implementation changes.

:::

Flow Credit Markets (FCM) is a next-generation DeFi lending platform built on the Flow blockchain that revolutionizes lending infrastructure by replacing reactive liquidations with proactive rebalancing. FCM consists of three core components: the Flow Active Lending Protocol (ALP) for automatic liquidation protection, MOET (Medium of Exchange Token) as the protocol-native stable asset, and Flow Yield Vaults (FYV) for automated yield strategies.

The platform enables users to deposit tokens into leveraged yield strategies. For example, the Tracer Strategy creates sophisticated token flows where users deposit FLOW tokens, which are used as collateral to borrow MOET (the overcollateralized stable asset used by FCM), which is then swapped to YieldTokens and managed by AutoBalancers for optimal yield generation.

## Learning Objectives

After completing this tutorial, you will be able to:

- Understand how Flow Credit Markets' three core components (ALP, FYV, and MOET) work together
- Create a position using the Flow CLI
- Inspect position state with Cadence scripts
- Identify how Flow Credit Markets tracks collateral, debt, and health

# Prerequisites

## Cadence Programming Language

This tutorial assumes you have a modest knowledge of [Cadence]. If you don't, you'll be able to follow along, but you'll get more out of it if you complete our series of [Cadence] tutorials. Most developers find it more pleasant than other blockchain languages and it's not hard to pick up.

## Working With Cadence

- [Flow CLI] installed and configured
- Basic understanding of Flow [accounts], [scripts], and [transactions]

## DeFi Principles

Before diving into Flow Credit Markets, it's helpful to understand some key DeFi concepts:

- **Collateralized Lending**: Using assets as collateral to borrow other assets
- **Yield Farming**: Strategies that generate returns on deposited assets
- **Auto-Balancing**: Automated systems that maintain optimal asset ratios
- **Position Health**: A metric that indicates the safety of a lending position, measured by Health Factor (HF)
- **Active Rebalancing**: Proactive position management that prevents liquidations through automated adjustments

## Flow Credit Markets: Three Core Components

Flow Credit Markets (FCM) is composed of three intertwined systems that work together to create a revolutionary lending and yield platform:

1. **Flow Active Lending Protocol (ALP)** - Provides automatic liquidation protection through active rebalancing
2. **MOET (Medium of Exchange Token)** - Serves as the protocol-native stable asset that unifies liquidity
3. **Flow Yield Vaults (FYV)** - Delivers automated yield strategies built on top of ALP

### Flow Active Lending Protocol (ALP)

The Flow Active Lending Protocol (ALP) is the foundational lending infrastructure that handles collateralized borrowing with active rebalancing:

- **Core Lending Infrastructure**: Handles collateralized borrowing with scheduled onchain transactions
- **Position Management**: Tracks collateral, debt, and health factors using Flow's unique scheduled callback architecture
- **Active Rebalancing**: Proactively rebalances positions to maintain target health factors, eliminating liquidation risk
- **100% Onchain Automation**: Leverages Flow's scheduled transactions for autonomous position management without external keepers

### MOET: Medium of Exchange Token

MOET (Medium of Exchange Token) is the core stable asset of Flow Credit Markets, engineered to unify liquidity, streamline treasury management, and provide a robust, composable unit of account for the entire ecosystem:

- **Dual-Backing Model**: Always fully backed—either by a 100% reserve of approved stablecoins or by volatile assets at a minimum 125% collateral ratio
- **Minting Mechanisms**:
  - **Stablecoin Deposits**: Users deposit approved stables (USDC, USDF) to mint MOET 1:1
  - **Collateral Borrowing**: Users open overcollateralized positions (≥125%) in ALP, minting MOET against collateral
- **Redemption**: Always available 1:1 for underlying stablecoin deposits, with dynamic fees that protect the peg
- **Protocol Integration**: Serves as the medium of exchange connecting ALP positions to FYV yield strategies

### Flow Yield Vaults (FYV)

Flow Yield Vaults (FYV) is the yield strategy layer built on top of ALP, enabling leveraged yield strategies:

- **Leveraged Yield Strategies**: Creates three-asset relationships (collateral, MOET debt, yield tokens) with automated management
- **Dual Position Management**: Monitors both protocol-layer (ALP) and vault-layer health factors independently
- **Automated Rebalancing**: Executes yield token sales to maintain healthy debt ratios during market volatility
- **Yield Token Integration**: Supports both cross-chain yield tokens (bridged via LayerZero OFT) and Flow-native tokenized yield products

### How the Components Work Together

The three components of FCM work in harmony:

1. **ALP** provides the lending infrastructure where users deposit collateral and borrow MOET
2. **MOET** serves as the stable medium of exchange, allowing non-stable collateral to access stablecoin yields
3. **FYV** uses ALP positions and MOET to create leveraged yield strategies, automatically managing the three-asset relationship (collateral, MOET debt, yield tokens)

When you create a YieldVault position in FYV:

- Your collateral is deposited into an ALP position
- ALP mints MOET against your collateral
- FYV swaps MOET for yield tokens
- Both ALP and FYV monitor and rebalance the position to maintain health and optimize yield

## Health Factor Framework and Dual Rebalancing System

Flow Credit Markets implements a sophisticated **health factor framework** with three levels of position management. Understanding health factors is crucial for managing leveraged positions safely.

### What is a Health Factor?

A **Health Factor (HF)** is a numerical ratio that represents the safety of a lending position. It's calculated as:

```
Health Factor = Effective Collateral Value / Effective Debt Value
```

**What the numbers mean:**

- **HF > 1.0**: Your collateral value exceeds your debt value - position is safe
- **HF = 1.0**: Your collateral exactly equals your debt - at liquidation threshold
- **HF < 1.0**: Your debt exceeds your collateral value - position is underwater and at risk

**Example Calculation:**

Let's say you have:

- **Collateral**: 100 FLOW tokens at $0.50 each = $50.00
- **Collateral Factor**: 0.8 (80% of value counts)
- **Effective Collateral**: $50.00 × 0.8 = $40.00
- **Debt**: 30 MOET at $1.00 each = $30.00
- **Borrow Factor**: 1.0 (100%)
- **Effective Debt**: $30.00 / 1.0 = $30.00

```
Health Factor = $40.00 / $30.00 = 1.33
```

This means your position has 133% collateralization - you have $1.33 in effective collateral for every $1.00 of debt.

### Health Factor (HF) Framework in FCM

Flow Credit Markets uses a three-tier health management system:

#### 1. Initial Health Factor

- **Definition**: User's starting position health when the position is first created
- **Typical Range**: 1.2 - 1.5 for new positions
- **Purpose**: Establishes the baseline safety level for the position

**Example**: When you deposit 100 FLOW and borrow 30 MOET, your initial health factor might be 1.33 (133% collateralization).

#### 2. Rebalancing Health Factor

- **Default Value**: 1.10 (110% collateralization)
- **Purpose**: The threshold that triggers automated rebalancing before liquidation risk
- **Action**: When health factor drops to 1.10, the system automatically intervenes to restore safety

**Example**: If your position health drops to 1.10, the system will:

- Sell yield tokens to repay MOET debt
- Add proceeds to collateral
- Restore health factor to target level

#### 3. Target Health Factor

- **Default Value**: 1.3 (130% collateralization)
- **Purpose**: The optimal health level the protocol maintains through automatic rebalancing
- **Post-Rebalancing**: After intervention, positions are restored to this target level

**Example**: After rebalancing triggers at 1.10, the system will restore your position to 1.30 health factor.

#### 4. Minimum Health (Liquidation Threshold)

- **Default Value**: 1.1 (110% collateralization)
- **Purpose**: The absolute minimum health before liquidation risk
- **FCM Advantage**: With active rebalancing, positions should never reach this threshold

### Health Factor Comparison: Aave vs Flow Credit Markets

#### Aave (Traditional Liquidation Model)

**Typical Health Factors:**

- **Liquidation Threshold**: 1.0 (100% collateralization)
- **Safe Position**: 1.5 - 2.0+ (150% - 200%+ collateralization)
- **At Risk**: Below 1.5
- **Critical**: Below 1.2

**How it works:**

- Health factor continuously decreases as debt accrues interest
- No automatic intervention - users must manually manage positions
- When HF drops below 1.0, position is liquidated
- Liquidation penalty: 5-10% of debt value
- Forced sale at market bottom during crisis

**Example Aave Position:**

```
Collateral: 100 ETH at $2,000 = $200,000
Debt: 150,000 USDC
Health Factor: $200,000 / $150,000 = 1.33

If ETH price drops to $1,500:
New Collateral Value: $150,000
New Health Factor: $150,000 / $150,000 = 1.0 (AT LIQUIDATION RISK!)

If ETH drops further to $1,400:
New Health Factor: $140,000 / $150,000 = 0.93 (LIQUIDATED!)
```

#### Flow Credit Markets (Active Rebalancing Model)

**Typical Health Factors:**

- **Liquidation Threshold**: 1.1 (110% collateralization) - but positions should never reach this
- **Rebalancing Trigger**: 1.10 (110% collateralization)
- **Target Health**: 1.3 (130% collateralization)
- **Safe Position**: 1.3+ maintained automatically

**How it works:**

- Health factor is continuously monitored via scheduled onchain transactions
- Automatic intervention at 1.10 before liquidation risk
- System sells yield tokens to repay debt and restore health
- Positions maintained at target 1.30 health factor
- No liquidation penalties - gradual cost-effective rebalancing

**Example FCM Position:**

```
Initial State:
Collateral: 100 FLOW at $0.50 = $50.00
Debt: 30 MOET = $30.00
Yield Tokens: 30 tokens at $1.00 = $30.00
Health Factor: ($50.00 × 0.8) / $30.00 = 1.33

If FLOW price drops to $0.40:
New Collateral Value: $40.00
New Health Factor: ($40.00 × 0.8) / $30.00 = 1.07

System automatically intervenes:
- Sells 5 Yield Tokens = $5.00
- Repays 5 MOET debt
- New Debt: 25 MOET = $25.00
- New Health Factor: ($40.00 × 0.8) / $25.00 = 1.28

System continues until health restored to 1.30 target
```

### Key Differences

| Aspect                    | Aave                                | Flow Credit Markets             |
| ------------------------- | ----------------------------------- | ------------------------------- |
| **Liquidation Threshold** | 1.0 (100%)                          | 1.1 (110%) - but never reached  |
| **Safe Position**         | 1.5-2.0+ (manual management)        | 1.3 (automatically maintained)  |
| **Intervention**          | None - user must act manually       | Automatic at 1.10               |
| **Cost of Protection**    | Liquidation penalty (5-10% of debt) | Small rebalancing fees (~$2-15) |
| **Market Stress**         | High liquidation risk               | Automatic protection            |
| **User Action Required**  | Constant monitoring                 | None - fully automated          |

### Why the FCM Approach is Superior

1. **Proactive Protection**: FCM intervenes at 1.10 before reaching critical levels, while Aave only acts at 1.0 (too late)
2. **Cost Efficiency**: FCM rebalancing costs ~$2-15 vs Aave liquidation penalties of $1,500-$50,000+
3. **No Manual Management**: FCM maintains positions automatically, while Aave requires constant user attention
4. **Market Recovery**: FCM positions survive market downturns and participate in recovery, while liquidated Aave positions are permanently closed

This tri-level health management strategy creates an early warning and intervention system that prevents positions from reaching critical liquidation zones.

### Dual Position Management Across ALP and FYV

Flow Yield Vaults implement a sophisticated two-tier health monitoring system that leverages both ALP and FYV components:

#### 1. Protocol Layer (Flow ALP)

- **Purpose**: Monitors collateral-to-MOET debt ratio at the base lending layer
- **Component**: Part of the ALP infrastructure
- **Triggers**: When health factor approaches rebalancing threshold (typically 1.10+)
- **Action**: Provides base layer solvency protection through automated rebalancing
- **Protection**: Uses scheduled onchain transactions to maintain position safety

#### 2. Vault Layer (Flow Yield Vaults)

- **Purpose**: Executes rebalancing through yield token sales to optimize for yield while preserving capital
- **Component**: Part of the FYV infrastructure
- **Triggers**: When yield token value moves outside optimal thresholds or health factors approach limits
- **Action**: Calculates optimal yield token sale quantities, executes trades through concentrated liquidity pools, and applies proceeds to MOET debt repayment
- **Optimization**: Ensures maximum yield generation while maintaining position health

These systems work together across ALP and FYV to provide comprehensive protection against liquidation while optimizing for yield generation. The protocol's proactive approach eliminates liquidation risk through continuous monitoring and automated intervention across both components.

## Setting Up Your Environment

Follow these steps to set up your local Flow emulator with Flow Credit Markets contracts.

First, clone the repository:

```bash
git clone https://github.com/onflow/tidal-sc tidal-sc
cd tidal-sc
```

**Step 1: Start the Flow Emulator**

Before running the setup script, you need to start the Flow emulator:

```bash
flow emulator start --persist
```

The `--persist` flag ensures that deployed contracts and state are preserved when the emulator is restarted, which is helpful during development and learning.

You should see output indicating the emulator is running on port 3569.

**Step 2: Deploy Contracts and Configure System**

Then, run the setup script to set up the project to run on the emulator:

```bash
./local/setup_emulator.sh
```

This script will:

- Install [DeFi Actions] dependencies
- Deploy all Flow Credit Markets contracts to the emulator
- Set up mock oracle prices (FLOW: $0.50, YieldToken: $1.00)
- Configure Flow Active Lending Protocol (ALP) with MOET as the default borrowing token and FLOW as collateral (collateral factor: 0.8)
- Set up liquidity connectors for mock swapping
- Register the Tracer Strategy
- Grant beta access to Flow Yield Vaults (required for creating YieldVaults during closed beta)

**Step 3: Verify Setup**

Check that the emulator is running and contracts are deployed:

```bash
flow accounts list --network emulator
```

You should see the emulator account with deployed contracts.

```zsh
📋 Account Status Across Networks

This shows which networks your configured accounts are accessible on:
🌐 Network  🟢 Local (running)  🔴 Local (stopped)  ✓ Found  ✗ Error
─────────────────────────────────────────────────────

🟢 emulator
    ✓ emulator-account (f8d6e0586b0a20c7): 999999999.99600000 FLOW
    ✗ evm-gateway (e03daebed8ca0615): Account not found
    ✗ mock-incrementfi (f3fcd2c1a78f5eee): Account not found
    ✗ test-user (179b6b1cb6755e31): Account not found

🌐 mainnet
  No accounts found

🌐 testnet
    ✓ testnet-admin (2ab6f469ee0dfbb6): 99999.99557095 FLOW

🟢 testing
    ✓ emulator-account (f8d6e0586b0a20c7): 999999999.99600000 FLOW
    ✗ evm-gateway (e03daebed8ca0615): Account not found
    ✗ mock-incrementfi (f3fcd2c1a78f5eee): Account not found
    ✗ test-user (179b6b1cb6755e31): Account not found


💡 Tip: To fund testnet accounts, run: flow accounts fund
```

**Important**: Keep the emulator running in a separate terminal window throughout this tutorial. If you stop the emulator, you'll need to restart it.

## Understanding Position Creation and IDs

Before creating positions, it's important to understand how the system works and the different types of identifiers involved.

### Borrowing Capacity Calculation

When you deposit collateral, the system calculates your maximum borrowing capacity using this formula:

```
Effective Collateral = Collateral Amount × Oracle Price × Collateral Factor
Max Borrowable Value = Effective Collateral / Target Health Factor
Max Borrowable Tokens = Max Borrowable Value / Borrow Token Price
```

**Example with 100 FLOW:**

- FLOW Price: $0.50 (from oracle)
- Collateral Factor: 0.8 (80%)
- Target Health Factor: 1.3 (130% collateralization) - this is the FCM target health
- MOET Price: $1.00

```
Effective Collateral = 100 FLOW × $0.50 × 0.8 = $40.00
Max Borrowable Value = $40.00 / 1.3 = $30.77
Max MOET Borrowable = $30.77 / $1.00 = 30.77 MOET
```

**What this means:**

- If you borrow the maximum (30.77 MOET), your initial health factor will be exactly 1.30
- This is the FCM target health factor - a safe, automatically maintained level
- Compare this to Aave, where safe positions typically need 1.5-2.0+ health factor (requiring more collateral for the same borrowing capacity)

**If you borrow less (e.g., 25 MOET):**

```
Initial Health Factor = $40.00 / $25.00 = 1.60
```

This gives you more safety buffer, but you're using less of your available borrowing capacity.

### Position ID vs YieldVault ID

The system uses two different identifiers:

- **Position ID (pid)**: Flow Active Lending Protocol (ALP) lending position identifier - tracks the actual lending/borrowing position in ALP
- **YieldVault ID**: Flow Yield Vaults (FYV) strategy wrapper identifier - tracks the yield strategy that wraps the ALP position

These are separate identifiers that serve different purposes across the FCM component architecture. Each YieldVault in FYV wraps an underlying ALP position, and both use MOET as the medium of exchange.

## Creating Your First Position

Now let's create a position using the Flow CLI. The process involves sending transactions to create a YieldVault position and then inspecting it with scripts.

### Step 1: Create Test Account

First, create a new test account that we'll use for this tutorial:

```bash
flow accounts create
```

Name it `fcm-test` and select `emulator` for the network.

This will generate a new account with a new key pair. The CLI will output the account address and key information - save this information as you'll need it for signing transactions.

Fund the account with:

```bash
flow accounts fund
```

Select the entry for:

```bash
0x0x179b6b1cb6755e31 (fcm-test) [emulator]
```

### Step 2: Grant Beta Access

Before setting up your account, you need to grant beta access to your `fcm-test` account. This is required during the closed beta phase:

```bash
# Grant beta access to your account
flow transactions send cadence/transactions/flow-yield-vaults/admin/grant_beta.cdc \
  --network emulator --payer emulator-account --proposer fcm-test --authorizer emulator-account,fcm-test
```

:::info

In a Cadence [transaction], the proposer, payer, and authorizer roles are all natively separate. Account abstraction (sponsored transactions) and multi-sig are supported out of the box.

:::

This transaction grants the necessary beta badge to your account, allowing it to create YieldVaults.

### Step 3: Set Up Your Account

Now ensure your account has the necessary setup for Flow Credit Markets:

```bash
# Setup user account with YieldVaultManager
flow transactions send cadence/transactions/flow-yield-vaults/setup.cdc \
  --network emulator --signer fcm-test
```

This transaction creates a `YieldVaultManager` resource in your account's storage and publishes the necessary capabilities.

**Note**: During the closed beta phase, beta access is required to create YieldVaults across all networks (emulator, testnet, mainnet). The `grant_beta` transaction grant this access to the selected account on the network it is called on.

### Step 4: Create a Position

Now let's create and manage a YieldVault position. First, let's check what strategies are available:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_supported_strategies.cdc --network emulator
```

You should see output similar to:

```
Result: [Type<A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy>()]
```

Create a YieldVault position with 100 FLOW tokens as collateral, using the Tracer strategy:

```bash
flow transactions send cadence/transactions/flow-yield-vaults/create_yield_vault.cdc \
  --network emulator --signer fcm-test \
  --args-json '[
    {"type":"String","value":"A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy"},
    {"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},
    {"type":"UFix64","value":"100.0"}
  ]'
```

This transaction orchestrates all three FCM components:

- **ALP**: Creates a lending position with 100 FLOW tokens as collateral
- **MOET**: Mints MOET against the collateral (based on collateral factor)
- **FYV**: Creates a YieldVault using the Tracer Strategy, swaps MOET for YieldTokens, and sets up the complete DeFi Actions stack including AutoBalancer
- Returns a YieldVault ID for future reference

### Step 5: Verify Position Creation

Check that your position was created successfully by querying your YieldVault IDs:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_yield_vault_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x179b6b1cb6755e31"}]'
```

Replace `0x179b6b1cb6755e31` with the address of your `fcm-test` account. You can find this address by running:

```bash
flow accounts list --network emulator
```

Look for the `fcm-test` account entry to get its address.

After running the script, you should see:

```bash
Result: [0]
```

This is the array of your YieldVault IDs. You've only created one, hence the `0` in the array. Your YieldVault position is live and ready for further operations.

### Review of the Core Contracts

Let's examine the main contracts that make Flow Credit Markets work:

#### 1. TidalYield.cdc - Flow Yield Vaults Main Contract

The main contract orchestrates the entire yield farming system:

- **Strategy Interface**: Defines yield-generating strategies that can deposit/withdraw tokens
- **YieldVault Resource**: Represents a user's position in a specific strategy within Flow Yield Vaults
- **YieldVaultManager**: Manages multiple YieldVault positions for a user account

#### 2. TidalYieldStrategies.cdc - Strategy Implementations

Implements the Tracer Strategy that demonstrates the power of DeFi Actions composition:

```cadence
access(all) resource TracerStrategy : TidalYield.Strategy, DeFiActions.IdentifiableResource {
    access(self) let position: TidalProtocol.Position
    access(self) var sink: {DeFiActions.Sink}
    access(self) var source: {DeFiActions.Source}

    // ... strategy implementation
}
```

#### 3. TidalYieldAutoBalancers.cdc - Auto-Balancing System

Manages automated rebalancing of positions:

- Stores AutoBalancer instances in contract storage
- Automatically rebalances positions when they move outside configured thresholds (±5%)
- Cleans up AutoBalancers when strategies are closed

### Understanding the FLOW → MOET → YieldToken Flow Across FCM Components

The Tracer Strategy demonstrates how the three FCM components work together to create a sophisticated token flow:

```
User Deposit (FLOW)
    ↓
[ALP Component] Flow Active Lending Protocol Position created
    ↓
[MOET Component] MOET minted against collateral
    ↓
[FYV Component] MOET swapped to YieldToken → AutoBalancer
    ↓
[FYV + ALP] YieldToken → Swap to FLOW → Recollateralize ALP Position
```

Here's how the three components interact:

1. **Initial Position Opening**:

   - **ALP**: User deposits FLOW → ALP creates a lending position
   - **MOET**: ALP mints MOET against the collateral (the overcollateralized stable asset)
   - **FYV**: FYV swaps MOET for YieldToken and holds it in AutoBalancer

2. **Auto-Balancing Infrastructure (FYV Component)**:

   - `abaSwapSink`: MOET → YieldToken → AutoBalancer
   - `abaSwapSource`: YieldToken → MOET (from AutoBalancer)
   - `positionSwapSink`: YieldToken → FLOW → ALP Position (recollateralizing)

3. **Rebalancing Triggers (Coordinated Across Components)**:
   - **Over-Collateralized** (YieldToken value > 105%): FYV sells excess YieldToken → Converts to FLOW → Adds to ALP Position Collateral
   - **Under-Collateralized** (YieldToken value < 95%): FYV sells YieldToken → Converts to FLOW → Adds to ALP Position Collateral → Reduces MOET debt risk

## Querying Your YieldVault Further

Check the balance of your YieldVault:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_yield_vault_balance.cdc \
  --network emulator \
  --args-json '[
    {"type":"Address","value":"0x179b6b1cb6755e31"},
    {"type":"UInt64","value":"0"}
  ]'
```

You'll see:

```bash
Result: 100.00000000
```

### Getting Complete Position Information

For a comprehensive view of your position, use the complete position info script:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_complete_user_position_info.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x179b6b1cb6755e31"}]'
```

This script returns detailed information including:

- Collateral information (FLOW balance and value)
- YieldToken information (balance, value, price)
- Debt information (estimated MOET debt)
- Health metrics (leverage ratio, health ratio, net worth)
- Portfolio summary across all positions

Your result will be similar to:

```bash
Result: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CompleteUserSummary(userAddress: 0x179b6b1cb6755e31, totalPositions: 1, portfolioSummary: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.PortfolioSummary(totalCollateralValue: 30.76923076, totalYieldTokenValue: 30.76923076, totalEstimatedDebtValue: 30.76923076, totalNetWorth: 30.76923076, averageLeverageRatio: 3.00000000, portfolioHealthRatio: 1.00000000), positions: [s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CompletePositionInfo(yieldVaultId: 0, collateralInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CollateralInfo(collateralType: "A.0ae53cb6e3f42a79.FlowToken.Vault", availableBalance: 30.76923076, collateralValue: 15.38461538, collateralPrice: 0.50000000, supportedTypes: ["A.0ae53cb6e3f42a79.FlowToken.Vault"]), yieldTokenInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.YieldTokenInfo(yieldTokenBalance: 30.76923076, yieldTokenValue: 30.76923076, yieldTokenPrice: 1.00000000, yieldTokenIdentifier: "A.f8d6e0586b0a20c7.YieldToken.Vault", isActive: true), debtInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.DebtInfo(estimatedMoetDebt: 30.76923076, estimatedDebtValue: 30.76923076, moetPrice: 1.00000000, loanTokenIdentifier: "A.f8d6e0586b0a20c7.MOET.Vault"), healthMetrics: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.HealthMetrics(realAvailableBalance: 30.76923076, estimatedCollateralValue: 15.38461538, liquidationRiskThreshold: 1.10000000, autoRebalanceThreshold: 1.10000000, optimalHealthRatio: 1.30000000, maxEfficiencyThreshold: 1.50000000, netWorth: 15.38461538, leverageRatio: 3.00000000, yieldTokenRatio: 1.00000000, estimatedHealth: 1300000.00000000))], timestamp: 1761068654.00000000)
```

### Understanding AutoBalancer Architecture

Each YieldVault gets its own dedicated AutoBalancer with a unique ID:

- **Global Storage**: AutoBalancers are stored in the `TidalYieldAutoBalancers` contract (not in user accounts)
- **Per-YieldVault**: Each YieldVault gets its own AutoBalancer identified by YieldVault ID (0, 1, 2, etc.)
- **Sequential IDs**: YieldVault IDs are assigned sequentially across all users
- **Multiple YieldVaults**: You can create multiple YieldVaults, each with its own AutoBalancer
- **Automatic Cleanup**: When you close a YieldVault, its AutoBalancer is automatically destroyed

**Example**: If you create YieldVault 0, another user creates YieldVault 1, and you create another YieldVault 2, you'll have AutoBalancers with IDs 0, 1, and 2 respectively. Users may have more than one YieldVault and more than one AutoBalancer.

Let's examine the AutoBalancer configuration. Your AutoBalancer ids match your yield vault ids, so if you want, you can run the script again to find them:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_yield_vault_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"YOUR_ACCOUNT_ADDRESS"}]'
```

Then, run the script to get the **balance** for one of the ids returned:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc \
  --network emulator \
  --args-json '[{"type":"UInt64","value":"0"}]'
```

You'll see something similar to:

```bash
Result: 30.76923076
```

This is the **raw balance** in the YieldToken from the mock contract.

Check the current USD **value** of the AutoBalancer:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_auto_balancer_current_value_by_id.cdc \
  --network emulator \
  --args-json '[
    {"type":"UInt64","value":"0"}
  ]'
```

You should see something similar to:

```bash
Result: 30.76923076
```

:::info

You may have noticed that these values are identical. This is because the emulator chain doesn't produce blocks unless you send a transaction, and because you've set the value of the YieldToken to $1.00 USD. So 30.76923076 \* 1.00 USD is $30.76923076.

:::

## Understanding the Strategy Architecture

The Tracer Strategy demonstrates sophisticated DeFi Actions composition. Let's examine how it works:

### Strategy Composition

The Tracer Strategy Composer creates a complex stack of DeFi Actions:

```cadence
// Configure AutoBalancer for this stack
let autoBalancer = TidalYieldAutoBalancers._initNewAutoBalancer(
    oracle: oracle,             // Price feeds for value calculations
    vaultType: yieldTokenType,  // YieldToken holdings monitored
    lowerThreshold: 0.95,       // Trigger recollateralization at 95%
    upperThreshold: 1.05,       // Trigger rebalancing at 105%
    rebalanceSink: positionSwapSink, // Where excess value goes
    rebalanceSource: nil,       // Not used in TracerStrategy
    uniqueID: uniqueID          // Links to specific Strategy
)

// MOET -> YieldToken swapper
let moetToYieldSwapper = MockSwapper.Swapper(
    inVault: moetTokenType,
    outVault: yieldTokenType,
    uniqueID: uniqueID
)

// SwapSink directing swapped funds to AutoBalancer
let abaSwapSink = SwapConnectors.SwapSink(swapper: moetToYieldSwapper, sink: abaSink, uniqueID: uniqueID)
```

### Auto-Balancing Mechanism

The AutoBalancer monitors the value of deposits vs. current token holdings:

- **Lower Threshold (95%)**: When YieldToken value drops below 95% of expected value, it triggers recollateralization
- **Upper Threshold (105%)**: When YieldToken value exceeds 105% of expected value, excess flows into position recollateralization

### Manual Rebalancing

You can manually trigger rebalancing:

```bash
flow transactions send cadence/transactions/flow-yield-vaults/admin/rebalance_auto_balancer_by_id.cdc \
  --network emulator --signer emulator-account \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"Bool","value":"true"}
  ]'
```

## Additional Operations

### Depositing Additional Funds

Add more funds to an existing YieldVault:

```bash
flow transactions send cadence/transactions/flow-yield-vaults/deposit_to_yield_vault.cdc \
  --network emulator --signer fcm-test \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"50.0"}
  ]'
```

You should see several events, and you can check that the balance changed in the account with `flow accounts list` and on the YieldVault with:

```bash
flow scripts execute cadence/scripts/flow-yield-vaults/get_yield_vault_balance.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x179b6b1cb6755e31"},{"type":"UInt64","value":"0"}]'
```

### Withdrawing from a YieldVault

Withdraw funds from your YieldVault:

```bash
flow transactions send cadence/transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc \
  --network emulator --signer fcm-test \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"25.0"}
  ]'
```

### Closing a YieldVault

Close your YieldVault and withdraw all funds:

```bash
flow transactions send cadence/transactions/flow-yield-vaults/close_yield_vault.cdc \
  --network emulator --signer fcm-test \
  --args-json '[{"type":"UInt64","value":"0"}]'
```

## Understanding the Token Flow in Detail Across FCM Components

Let's trace through what happens when you create a YieldVault, showing how ALP, MOET, and FYV work together:

### 1. Initial Deposit Flow

```
User deposits 100 FLOW
    ↓
[ALP Component] Flow Active Lending Protocol Position created
    ↓
[MOET Component] ALP mints MOET against collateral (125% overcollateralized)
    ↓
[FYV Component] MOET → Swap to YieldToken (via MockSwapper)
    ↓
[FYV Component] YieldToken deposited to AutoBalancer
    ↓
[ALP + FYV] Both components monitor value ratios and health factors
```

### 2. Auto-Balancing Flow (Coordinated Across Components)

**When YieldToken value > 105% of expected:**

```
[FYV Component] Excess YieldToken detected
    ↓
[FYV Component] Swap to FLOW (via positionSwapSink)
    ↓
[ALP Component] Add FLOW to Position Collateral
    ↓
[ALP Component] MOET debt ratio improves, position becomes healthier
```

**When YieldToken value < 95% of expected:**

```
[FYV Component] YieldToken value drops below threshold
    ↓
[FYV Component] Swap YieldToken to FLOW (via positionSwapSink)
    ↓
[ALP Component] Add FLOW to Position Collateral
    ↓
[ALP Component] Reduce MOET debt risk, improve health ratio
```

### 3. Value Calculations

The system uses oracle prices to calculate values:

- FLOW Price: $0.50 (set in MockOracle)
- YieldToken Price: $1.00 (set in MockOracle)
- MOET Price: $1.00 (Medium of Exchange Token, always fully backed by stablecoins or 125% overcollateralized positions)

Health calculations:

- Collateral Value = FLOW Amount × FLOW Price
- YieldToken Value = YieldToken Amount × YieldToken Price
- Debt Value = MOET Amount × MOET Price
- Health Ratio = (Collateral Value + YieldToken Value) / Debt Value

## Conclusion

In this tutorial, you learned about Flow Credit Markets (FCM), a next-generation DeFi lending platform built on Flow that revolutionizes lending infrastructure by replacing reactive liquidations with proactive rebalancing. FCM is composed of three core components that work together:

- **Flow Active Lending Protocol (ALP)**: Provides automatic liquidation protection through active rebalancing
- **MOET (Medium of Exchange Token)**: Serves as the protocol-native stable asset that unifies liquidity
- **Flow Yield Vaults (FYV)**: Delivers automated yield strategies built on top of ALP

You explored:

- How to deploy the Flow Credit Markets emulator environment with all three components
- How ALP, MOET, and FYV work together in the FLOW → MOET → YieldToken flow to generate yield
- How to create and manage YieldVault positions that leverage all three FCM components
- How the dual rebalancing system coordinates across ALP and FYV to maintain optimal position ratios automatically
- How to query comprehensive position information including health factors across components
- The sophisticated DeFi Actions composition that powers the platform
- How scheduled onchain transactions enable 100% autonomous position management across ALP and FYV

The Tracer Strategy demonstrates how the three FCM components work together, with ALP providing the lending infrastructure, MOET serving as the stable medium of exchange, and FYV creating a self-balancing yield farming position that automatically optimizes returns while managing risk through intelligent rebalancing mechanisms. Unlike traditional liquidation-based protocols, the FCM active rebalancing approach eliminates liquidation risk through continuous monitoring and automated intervention across all components.

Flow Credit Markets represents a fundamental advancement in DeFi infrastructure, demonstrating that active rebalancing can eliminate the liquidation risks that have constrained lending protocol adoption. Through the coordinated operation of ALP, MOET, and FYV, along with sophisticated automation, concentrated liquidity optimization, and the Flow blockchain's unique capabilities, FCM delivers superior cost efficiency while preserving user positions during market stress.

<!-- Reference-style links, will not render on page. -->

[Cadence]: https://cadence-lang.org/docs
[DeFi Actions]: https://developers.flow.com/blockchain-development-tutorials/forte/flow-actions
[Flow Active Lending Protocol]: https://github.com/onflow/tidal-protocol
[Flow CLI]: https://developers.flow.com/tools/flow-cli
[accounts]: https://developers.flow.com/build/cadence/basics/accounts
[scripts]: https://developers.flow.com/build/cadence/basics/scripts
[transactions]: https://developers.flow.com/build/cadence/basics/transactions
