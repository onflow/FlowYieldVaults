---
title: Hello Tidal: Create and Inspect a Position
description: Learn how to create and inspect Tidal positions using the frontend and CLI tools
sidebar_position: 1
keywords:
  - tidal protocol
  - high tide
  - yield farming
  - flow blockchain
  - cadence smart contracts
  - defi strategies
  - position management
  - tidal protocol
  - moet
  - yield tokens
  - position health
---

TODO: REPLACE 0x179b6b1cb6755e31 with YOUR_ACCOUNT_ADDRESS

# Hello Tidal: Create and Inspect a Position

:::warning

Tidal is currently in closed beta. This tutorial demonstrates the core concepts using mock contracts and the Flow emulator. The specific implementation may change as development progresses.

These tutorials will be updated, but you may need to refactor your code if the implementation changes.

:::

Tidal is a yield farming platform built on the Flow blockchain that enables users to deposit tokens into supported DeFi strategies such as collateralized borrowing via Tidal Protocol's Active Lending Platform. Tidal aims to support yield-generating strategies, automatically optimizing returns through DeFi Actions components and auto-balancing mechanisms.

The platform is designed to support multiple yield-generating strategies. For example, the Tracer Strategy creates sophisticated token flows where users deposit FLOW tokens, which are used as collateral to borrow MOET (Tidal Protocol's synthetic stablecoin), which is then swapped to YieldTokens and managed by AutoBalancers for optimal yield generation.

## Learning Objectives

After completing this tutorial, you will be able to:

- Understand the relationship between Tidal Protocol and High Tide
- Create a position using the Flow CLI
- Inspect position state with Cadence scripts
- Identify how Tidal tracks collateral, debt, and health

# Prerequisites

## Cadence Programming Language

This tutorial assumes you have a modest knowledge of [Cadence]. If you don't, you'll be able to follow along, but you'll get more out of it if you complete our series of [Cadence] tutorials. Most developers find it more pleasant than other blockchain languages and it's not hard to pick up.

## Working With Cadence

- [Flow CLI] installed and configured
- Basic understanding of Flow [accounts], [scripts], and [transactions]

## DeFi Principles

Before diving into Tidal, it's helpful to understand some key DeFi concepts:

- **Collateralized Lending**: Using assets as collateral to borrow other assets
- **Yield Farming**: Strategies that generate returns on deposited assets
- **Auto-Balancing**: Automated systems that maintain optimal asset ratios
- **Position Health**: A metric that indicates the safety of a lending position

## Understanding Tidal Protocol vs High Tide

It's important to understand the relationship between these two components:

### Tidal Protocol

- **Core Lending Infrastructure**: The underlying protocol that handles collateralized borrowing
- **MOET Stablecoin**: Issues synthetic stablecoins backed by collateral
- **Position Management**: Tracks collateral, debt, and health ratios
- **Risk Management**: Implements liquidation mechanisms and health monitoring
- **Automatic Rebalancing**: Automatically rebalances positions to maintain target health ratios and prevent liquidation

### High Tide (TidalYield)

- **Yield Strategy Layer**: Built on top of Tidal Protocol
- **Strategy Composers**: Create complex DeFi strategies using Tidal Protocol positions
- **Auto-Balancing**: Automatically optimizes positions for maximum yield
- **Tide Management**: User-friendly interface for managing yield positions

Think of it this way: Tidal Protocol provides the lending infrastructure, while High Tide provides the yield optimization strategies that use that infrastructure.

## Dual Rebalancing System

Tidal implements a sophisticated **dual rebalancing system** with two complementary mechanisms:

### 1. Tidal Protocol Position Rebalancing

- **Purpose**: Maintains healthy collateralization ratios for lending positions
- **Triggers**: When position health falls below target (1.3) or minimum (1.1) thresholds
- **Action**: Automatically adjusts collateral/debt ratios to prevent liquidation
- **Protection**: Uses top-up sources and repayment sources to maintain position safety

### 2. High Tide AutoBalancer Rebalancing

- **Purpose**: Maintains optimal ratio between YieldToken holdings and expected deposit value
- **Triggers**: When YieldToken value moves outside ±5% thresholds (0.95-1.05)
- **Action**: Swaps excess YieldToken to FLOW and recollateralizes the position
- **Optimization**: Ensures maximum yield while maintaining position health

These systems work together to provide comprehensive protection against liquidation while optimizing for yield generation.

**In summary**: Automatic balancing exists in **both** Tidal and High Tide:

- **Tidal** (Tidal Protocol) = Automatic balancing for liquidation protection
- **High Tide** (TidalYield) = Automatic balancing for yield optimization

## Setting Up Your Environment

Follow these steps to set up your local Flow emulator with Tidal contracts.

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
- Deploy all Tidal contracts to the emulator
- Set up mock oracle prices (FLOW: $0.50, YieldToken: $1.00)
- Configure Tidal Protocol with MOET as default token and FLOW as collateral (collateral factor: 0.8)
- Set up liquidity connectors for mock swapping
- Register the Tracer Strategy
- Grant beta access to TidalYield (required for creating Tides during closed beta)

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
Max Borrowable Value = Effective Collateral ÷ Target Health
Max Borrowable Tokens = Max Borrowable Value ÷ Borrow Token Price
```

**Example with 100 FLOW:**

- FLOW Price: $0.50 (from oracle)
- Collateral Factor: 0.8 (80%)
- Target Health: 1.3 (130% collateralization)

```
Effective Collateral = 100 FLOW × $0.50 × 0.8 = $40
Max Borrowable Value = $40 ÷ 1.3 = $30.77
Max MOET Borrowable = $30.77 ÷ $1.00 = 30.77 MOET
```

### Position ID vs Tide ID

The system uses two different identifiers:

- **Position ID (pid)**: Tidal Protocol lending position identifier - tracks the actual lending/borrowing position
- **Tide ID**: TidalYield strategy wrapper identifier - tracks the yield strategy that wraps the position

These are separate identifiers that serve different purposes in the dual-layer architecture.

## Creating Your First Position

Now let's create a position using the Flow CLI. The process involves sending transactions to create a Tide position and then inspecting it with scripts.

### Step 1: Create Test Account

First, create a new test account that we'll use for this tutorial:

```bash
flow accounts create
```

Name it `tidal-test` and select `emulator` for the network.

This will generate a new account with a new key pair. The CLI will output the account address and key information - save this information as you'll need it for signing transactions.

Fund the account with:

```bash
flow accounts fund
```

Select the entry for:

```bash
0x0x179b6b1cb6755e31 (tidal-test) [emulator]
```

### Step 2: Grant Beta Access

Before setting up your account, you need to grant beta access to your `tidal-test` account. This is required during the closed beta phase:

```bash
# Grant beta access to your account
flow transactions send cadence/transactions/tidal-yield/admin/grant_beta.cdc \
  --network emulator --payer emulator-account --proposer tidal-test --authorizer emulator-account,tidal-test
```

:::info

In a Cadence [transaction], the proposer, payer, and authorizer roles are all natively separate. Account abstraction (sponsored transactions) and multi-sig are supported out of the box.

:::

This transaction grants the necessary beta badge to your account, allowing it to create Tides.

### Step 3: Set Up Your Account

Now ensure your account has the necessary setup for Tidal:

```bash
# Setup user account with TideManager
flow transactions send cadence/transactions/tidal-yield/setup.cdc \
  --network emulator --signer tidal-test
```

This transaction creates a `TideManager` resource in your account's storage and publishes the necessary capabilities.

**Note**: During the closed beta phase, beta access is required to create Tides across all networks (emulator, testnet, mainnet). The `grant_beta` transaction grant this access to the selected account on the network it is called on.

### Step 4: Create a Position

Now let's create and manage a Tide position. First, let's check what strategies are available:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_supported_strategies.cdc --network emulator
```

You should see output similar to:

```
Result: [Type<A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy>()]
```

Create a Tide position with 100 FLOW tokens as collateral, using the Tracer strategy:

```bash
flow transactions send cadence/transactions/tidal-yield/create_tide.cdc \
  --network emulator --signer tidal-test \
  --args-json '[
    {"type":"String","value":"A.f8d6e0586b0a20c7.TidalYieldStrategies.TracerStrategy"},
    {"type":"String","value":"A.0ae53cb6e3f42a79.FlowToken.Vault"},
    {"type":"UFix64","value":"100.0"}
  ]'
```

This transaction:

- Creates a new Tide using the Tracer Strategy
- Deposits 100 FLOW tokens as initial collateral
- Sets up the complete DeFi Actions stack including AutoBalancer
- Returns a Tide ID for future reference

### Step 5: Verify Position Creation

Check that your position was created successfully by querying your Tide IDs:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x179b6b1cb6755e31"}]'
```

Replace `0x179b6b1cb6755e31` with the address of your `tidal-test` account. You can find this address by running:

```bash
flow accounts list --network emulator
```

Look for the `tidal-test` account entry to get its address.

After running the script, you should see:

```bash
Result: [0]
```

This is the array of your Tide IDs. You've only created one, hence the `0` in the array. Your Tide position is live and ready for further operations.

### Review of the Core Contracts

Let's examine the main contracts that make Tidal work:

#### 1. TidalYield.cdc - Main Platform Contract

The main contract orchestrates the entire yield farming system:

- **Strategy Interface**: Defines yield-generating strategies that can deposit/withdraw tokens
- **Tide Resource**: Represents a user's position in a specific strategy
- **TideManager**: Manages multiple Tide positions for a user account

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

### Understanding the FLOW → MOET → YieldToken Flow

The Tracer Strategy creates a sophisticated token flow:

```
User Deposit (FLOW) → Tidal Protocol Position → MOET Issuance → Swap to YieldToken → AutoBalancer
                                               ↑
                                         YieldToken → Swap to FLOW → Recollateralize Position
```

Here's how it works:

1. **Initial Position Opening**:

   - User deposits FLOW → Tidal Protocol Position
   - Position issues MOET → Swaps to YieldToken
   - YieldToken held in AutoBalancer

2. **Auto-Balancing Infrastructure**:

   - `abaSwapSink`: MOET → YieldToken → AutoBalancer
   - `abaSwapSource`: YieldToken → MOET (from AutoBalancer)
   - `positionSwapSink`: YieldToken → FLOW → Position (recollateralizing)

3. **Rebalancing Triggers**:
   - **Over-Collateralized** (YieldToken value > 105%): Excess YieldToken → Swap to FLOW → Add to Position Collateral
   - **Under-Collateralized** (YieldToken value < 95%): YieldToken → Swap to FLOW → Add to Position Collateral → Reduce loan risk

## Querying Your Tide Further

Check the balance of your Tide:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_tide_balance.cdc \
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
flow scripts execute cadence/scripts/tidal-yield/get_complete_user_position_info.cdc \
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
Result: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CompleteUserSummary(userAddress: 0x179b6b1cb6755e31, totalPositions: 1, portfolioSummary: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.PortfolioSummary(totalCollateralValue: 30.76923076, totalYieldTokenValue: 30.76923076, totalEstimatedDebtValue: 30.76923076, totalNetWorth: 30.76923076, averageLeverageRatio: 3.00000000, portfolioHealthRatio: 1.00000000), positions: [s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CompletePositionInfo(tideId: 0, collateralInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.CollateralInfo(collateralType: "A.0ae53cb6e3f42a79.FlowToken.Vault", availableBalance: 30.76923076, collateralValue: 15.38461538, collateralPrice: 0.50000000, supportedTypes: ["A.0ae53cb6e3f42a79.FlowToken.Vault"]), yieldTokenInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.YieldTokenInfo(yieldTokenBalance: 30.76923076, yieldTokenValue: 30.76923076, yieldTokenPrice: 1.00000000, yieldTokenIdentifier: "A.f8d6e0586b0a20c7.YieldToken.Vault", isActive: true), debtInfo: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.DebtInfo(estimatedMoetDebt: 30.76923076, estimatedDebtValue: 30.76923076, moetPrice: 1.00000000, loanTokenIdentifier: "A.f8d6e0586b0a20c7.MOET.Vault"), healthMetrics: s.16ac6f2142667a95c3d09f33ee8a8fdf4455d56865960df49589e0882c801680.HealthMetrics(realAvailableBalance: 30.76923076, estimatedCollateralValue: 15.38461538, liquidationRiskThreshold: 1.10000000, autoRebalanceThreshold: 1.10000000, optimalHealthRatio: 1.30000000, maxEfficiencyThreshold: 1.50000000, netWorth: 15.38461538, leverageRatio: 3.00000000, yieldTokenRatio: 1.00000000, estimatedHealth: 1300000.00000000))], timestamp: 1761068654.00000000)
```

### Understanding AutoBalancer Architecture

Each Tide gets its own dedicated AutoBalancer with a unique ID:

- **Global Storage**: AutoBalancers are stored in the `TidalYieldAutoBalancers` contract (not in user accounts)
- **Per-Tide**: Each Tide gets its own AutoBalancer identified by Tide ID (0, 1, 2, etc.)
- **Sequential IDs**: Tide IDs are assigned sequentially across all users
- **Multiple Tides**: You can create multiple Tides, each with its own AutoBalancer
- **Automatic Cleanup**: When you close a Tide, its AutoBalancer is automatically destroyed

**Example**: If you create Tide 0, another user creates Tide 1, and you create another Tide 2, you'll have AutoBalancers with IDs 0, 1, and 2 respectively. Users may have more than one Tide and more than one AutoBalancer.

Let's examine the AutoBalancer configuration. Your AutoBalancer ids match your tide ids, so if you want, you can run the script again to find them:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_tide_ids.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"YOUR_ACCOUNT_ADDRESS"}]'
```

Then, run the script to get the **balance** for one of the ids returned:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
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
flow scripts execute cadence/scripts/tidal-yield/get_auto_balancer_current_value_by_id.cdc \
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
flow transactions send cadence/transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --network emulator --signer emulator-account \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"Bool","value":"true"}
  ]'
```

## Additional Operations

### Depositing Additional Funds

Add more funds to an existing Tide:

```bash
flow transactions send cadence/transactions/tidal-yield/deposit_to_tide.cdc \
  --network emulator --signer tidal-test \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"50.0"}
  ]'
```

You should see several events, and you can check that the balance changed in the account with `flow accounts list` and on the Tide with:

```bash
flow scripts execute cadence/scripts/tidal-yield/get_tide_balance.cdc \
  --network emulator \
  --args-json '[{"type":"Address","value":"0x179b6b1cb6755e31"},{"type":"UInt64","value":"0"}]'
```

### Withdrawing from a Tide

Withdraw funds from your Tide:

```bash
flow transactions send cadence/transactions/tidal-yield/withdraw_from_tide.cdc \
  --network emulator --signer tidal-test \
  --args-json '[
    {"type":"UInt64","value":"0"},
    {"type":"UFix64","value":"25.0"}
  ]'
```

### Closing a Tide

Close your Tide and withdraw all funds:

```bash
flow transactions send cadence/transactions/tidal-yield/close_tide.cdc \
  --network emulator --signer tidal-test \
  --args-json '[{"type":"UInt64","value":"0"}]'
```

## Understanding the Token Flow in Detail

Let's trace through what happens when you create a Tide:

### 1. Initial Deposit Flow

```
User deposits 100 FLOW
    ↓
Tidal Protocol Position created
    ↓
Position issues MOET (based on collateral factor 0.8 = 80 FLOW worth)
    ↓
MOET → Swap to YieldToken (via MockSwapper)
    ↓
YieldToken deposited to AutoBalancer
    ↓
AutoBalancer monitors value ratios
```

### 2. Auto-Balancing Flow

**When YieldToken value > 105% of expected:**

```
Excess YieldToken
    ↓
Swap to FLOW (via positionSwapSink)
    ↓
Add FLOW to Position Collateral
    ↓
Position becomes healthier
```

**When YieldToken value < 95% of expected:**

```
YieldToken
    ↓
Swap to FLOW (via positionSwapSink)
    ↓
Add FLOW to Position Collateral
    ↓
Reduce loan risk, improve health ratio
```

### 3. Value Calculations

The system uses oracle prices to calculate values:

- FLOW Price: $0.50 (set in MockOracle)
- YieldToken Price: $1.00 (set in MockOracle)
- MOET Price: $1.00 (stablecoin)

Health calculations:

- Collateral Value = FLOW Amount × FLOW Price
- YieldToken Value = YieldToken Amount × YieldToken Price
- Debt Value = MOET Amount × MOET Price
- Health Ratio = (Collateral Value + YieldToken Value) / Debt Value

## Conclusion

In this tutorial, you learned about Tidal, a sophisticated yield farming platform built on Flow that enables users to deposit tokens into yield-generating strategies with automatic optimization through DeFi Actions and auto-balancing mechanisms.

You explored:

- How to deploy the Tidal emulator environment with all necessary contracts
- The FLOW → MOET → YieldToken flow and how it generates yield
- How to create and manage Tide positions
- How AutoBalancers maintain optimal position ratios automatically
- How to query comprehensive position information
- The sophisticated DeFi Actions composition that powers the platform

The Tracer Strategy demonstrates the power of composable DeFi Actions, creating a self-balancing yield farming position that automatically optimizes returns while managing risk through intelligent rebalancing mechanisms.

Tidal represents a significant advancement in DeFi infrastructure, enabling complex yield strategies that were previously impossible to implement on-chain due to the limitations of traditional blockchain architectures.

<!-- Reference-style links, will not render on page. -->

[Cadence]: https://cadence-lang.org/docs
[DeFi Actions]: https://developers.flow.com/blockchain-development-tutorials/forte/flow-actions
[Tidal Protocol]: https://github.com/onflow/tidal-protocol
[Flow CLI]: https://developers.flow.com/tools/flow-cli
[accounts]: https://developers.flow.com/build/cadence/basics/accounts
[scripts]: https://developers.flow.com/build/cadence/basics/scripts
[transactions]: https://developers.flow.com/build/cadence/basics/transactions
