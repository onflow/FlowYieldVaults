# Tidal Smart Contracts

Tidal is a yield farming platform built on the Flow blockchain using Cadence 1.0. The platform enables users to deposit tokens into yield-generating strategies that automatically optimize returns through DeFiBlocks components and auto-balancing mechanisms.

## System Architecture

The Tidal platform consists of several interconnected components:

### Core Contracts

#### 1. Tidal.cdc - Main Platform Contract
The main contract that orchestrates the entire yield farming system:

- **Strategy Interface**: Defines yield-generating strategies that can deposit/withdraw tokens
- **StrategyComposer**: Creates and manages different strategy implementations  
- **StrategyFactory**: Manages multiple strategy composers and creates strategy instances
- **Tide Resource**: Represents a user's position in a specific strategy
- **TideManager**: Manages multiple Tide positions for a user account

#### 2. TidalYieldStrategies.cdc - Strategy Implementations
Implements specific yield strategies:

- **TracerStrategy**: A strategy that uses TidalProtocol lending positions with auto-balancing
- **TracerStrategyComposer**: Creates TracerStrategy instances with complex DeFiBlocks stacking
- **StrategyComposerIssuer**: Controls access to strategy composer creation

#### 3. TidalYieldAutoBalancers.cdc - Auto-Balancing System
Manages automated rebalancing of positions:

- Stores AutoBalancer instances in contract storage
- Automatically rebalances positions when they move outside configured thresholds
- Cleans up AutoBalancers when strategies are closed

### Token Contracts

#### YieldToken.cdc & MOET.cdc
Mock FungibleToken implementations representing:
- **YieldToken**: Receipt tokens for yield-bearing positions
- **MOET**: TidalProtocol's synthetic stablecoin

### Mock Infrastructure

#### MockOracle.cdc
- Provides price feeds for testing and demonstrations
- Supports price manipulation for testing scenarios
- Implements DFB.PriceOracle interface

#### MockSwapper.cdc  
- Simulates token swapping functionality
- Uses oracle prices to calculate swap rates
- Manages liquidity connectors for different token pairs

## How the System Works

### 1. Strategy Architecture
The TracerStrategy demonstrates the power of DeFiBlocks composition:

```
User Deposit (FLOW) → TidalProtocol Position → MOET Issuance → Swap to YieldToken → AutoBalancer
                                               ↑
                                         YieldToken → Swap to FLOW → Recollateralize Position
```

### 2. Auto-Balancing Mechanism
- AutoBalancers monitor the value of deposits vs. current token holdings
- When balance moves outside configured thresholds (±5%), automatic rebalancing occurs
- Excess value flows into position recollateralization
- Insufficient value triggers position adjustments

### 3. DeFiBlocks Integration
The system heavily uses DeFiBlocks components:
- **Sinks**: Accept token deposits
- **Sources**: Provide token withdrawals  
- **Swappers**: Handle token conversions
- **AutoBalancers**: Maintain optimal position ratios

## User Interactions

### Scripts (Read Operations)

#### `scripts/tidal-yield/get_tide_ids.cdc`
```cadence
// Returns all Tide IDs for a given user address
access(all) fun main(address: Address): [UInt64]?
```

#### `scripts/tokens/get_balance.cdc`
```cadence  
// Get token balance for an account
access(all) fun main(account: Address, vaultPath: StoragePath): UFix64
```

### Transactions (Write Operations)

#### Setup
```cadence
// Setup user account for Tidal platform
transaction setup()
```

#### Creating Tides
```cadence
// Create a new yield position
transaction create_tide(strategyIdentifier: String, vaultIdentifier: String, amount: UFix64)
```

#### Managing Positions
```cadence
// Deposit additional funds to existing Tide
transaction deposit_to_tide(id: UInt64, amount: UFix64)

// Withdraw funds from a Tide  
transaction withdraw_from_tide(id: UInt64, amount: UFix64)

// Close a Tide and withdraw all funds
transaction close_tide(id: UInt64)
```

## Development Environment

### Local Setup
The `local/setup_emulator.sh` script provides emulator configuration for local development and testing.

### Flow Configuration
`flow.json` contains network configurations and contract deployment settings.

## Rebalancing and Recollateralizing

The Tidal platform implements sophisticated automatic rebalancing and recollateralizing mechanisms to maintain healthy loan positions and optimize yield generation.

### How Auto-Balancing Works

Each TracerStrategy includes an AutoBalancer with configured thresholds:
- **Lower Threshold: 0.95** (5% below target)
- **Upper Threshold: 1.05** (5% above target)

The AutoBalancer continuously monitors the **value ratio** between:
- Current YieldToken holdings (actual balance)
- Expected value based on initial deposits (target balance)

### Rebalancing Scenarios

#### 1. Over-Collateralized Position (Upper Threshold Exceeded)
**When:** YieldToken value > 105% of expected value
**Cause:** Collateral price increased or yield generated excess tokens
**Action:** Position can support more borrowing

**Automated Flow:**
```
YieldToken (excess) → Swap to FLOW → Deposit to TidalProtocol Position → Issue more MOET → Swap to YieldToken
```

**Result:** 
- Increased borrowing capacity utilized
- More MOET borrowed against higher collateral value
- Additional YieldToken acquired for continued yield generation

#### 2. Under-Collateralized Position (Lower Threshold Breached)
**When:** YieldToken value < 95% of expected value  
**Cause:** Collateral price dropped or lending position at risk
**Action:** Position needs more collateral to maintain healthy loan-to-value ratio

**Automated Flow:**
```
YieldToken → Swap to FLOW → Add to Position Collateral → Reduce loan risk
```

**Result:**
- Position becomes healthier with improved collateralization ratio
- Reduced liquidation risk
- Maintained borrowing capacity

### Technical Implementation

#### AutoBalancer Configuration
```cadence
let autoBalancer = TidalYieldAutoBalancers._initNewAutoBalancer(
    oracle: oracle,               // Price feeds for value calculations
    vaultType: yieldTokenType,    // YieldToken holdings monitored
    lowerThreshold: 0.95,         // Trigger recollateralization at 95%
    upperThreshold: 1.05,         // Trigger rebalancing at 105%
    rebalanceSink: positionSwapSink, // Where excess value goes
    rebalanceSource: nil,         // Not used in TracerStrategy
    uniqueID: uniqueID           // Links to specific Strategy
)
```

#### Token Flow Architecture
The system creates a sophisticated token flow:

1. **Initial Position Opening:**
   - User deposits FLOW → TidalProtocol Position
   - Position issues MOET → Swaps to YieldToken
   - YieldToken held in AutoBalancer

2. **Rebalancing Infrastructure:**
   - `abaSwapSink`: MOET → YieldToken → AutoBalancer
   - `abaSwapSource`: YieldToken → MOET (from AutoBalancer)  
   - `positionSwapSink`: YieldToken → FLOW → Position (recollateralizing)

### Manual vs Automatic Rebalancing

#### Automatic Rebalancing
- Triggered when deposits/withdrawals push ratios outside thresholds
- Happens during normal Strategy operations
- No user intervention required

#### Manual Rebalancing  
**Transaction:** `transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc`

```cadence
// Force rebalancing regardless of thresholds
transaction rebalance_auto_balancer_by_id(id: UInt64, force: Bool)
```

**Parameters:**
- `id`: Tide ID associated with the AutoBalancer
- `force`: Whether to bypass threshold checks

### Monitoring Rebalancing

#### Check AutoBalancer Balance
**Script:** `scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc`

```cadence
// Returns current YieldToken balance in AutoBalancer
access(all) fun main(id: UInt64): UFix64?
```

#### Monitor Position Health
Users can track their position status by comparing:
- AutoBalancer YieldToken balance (actual)
- Expected value based on deposits (target)
- Current price ratios from oracle

### Benefits of Automated Rebalancing

1. **Risk Management**: Prevents liquidation by maintaining healthy collateral ratios
2. **Capital Efficiency**: Maximizes borrowing capacity when collateral appreciates  
3. **Yield Optimization**: Continuously adjusts to market conditions
4. **User Experience**: No manual intervention required for position maintenance

### Integration with DeFiBlocks

The rebalancing system leverages DeFiBlocks components:

- **Sinks**: Route tokens into rebalancing flows
- **Sources**: Extract tokens for rebalancing operations
- **Swappers**: Convert between token types (MOET ↔ YieldToken ↔ FLOW)
- **Oracle**: Provides price data for value calculations
- **AutoBalancer**: Central coordination of rebalancing logic

This creates a fully automated yield farming system that adapts to market conditions while maintaining position safety.

## Testing Rebalancing

This section provides a step-by-step guide to test rebalancing functionality in the mock environment by manipulating collateral prices and observing the automatic rebalancing effects.

### Diagram 1: Collateral Token (FLOW) Price Changes

```
                            COLLATERAL PRICE REBALANCING WITH CONTRACT INTERACTIONS

┌──────────────────────────────────── FLOW PRICE UP (+20%) ─────────────────────────────────────┐
│                                                                                                │
│  MockOracle.cdc: FLOW $1.00 → $1.20 (+20%)                                                    │
│  Status: OVER-COLLATERALIZED | Trigger: Ratio > 1.05                                          │
│                                                                                                │
│  ┌─────────────────┐ 1. Price Check ┌──────────────────────┐ 2. Threshold   ┌─────────────────┐ │
│  │   MockOracle    │───────────────►│TidalYieldAutoBalancer│─────Exceeded──►│   AutoBalancer  │ │
│  │                 │                │       .cdc           │                │   (DFB.cdc)     │ │
│  │ FLOW: $1.20     │                └──────────────────────┘                │ Rebalance Sink  │ │
│  └─────────────────┘                                                        └─────────────────┘ │
│                                                                                        │         │
│                                                3. Trigger Rebalancing                  │         │
│                                                         │                             │         │
│                                                         ▼                             │         │
│  ┌─────────────────┐ 4. More Collat ┌──────────────────────┐ 5. Issue MOET ┌─────────────────┐ │
│  │ TidalProtocol   │◄───────────────│  TracerStrategy      │◄──────────────│  TidalProtocol  │ │
│  │   Position      │   Value         │(TidalYieldStrategies │   Loan        │     Pool        │ │
│  │                 │                │       .cdc)          │               │                 │ │
│  │ Collateral: FLOW│                └──────────────────────┘               └─────────────────┘ │
│  └─────────────────┘                            │                                             │
│                                                  │ 6. MOET → YieldToken                       │
│                                                  ▼                                             │
│  ┌─────────────────┐ 7. Receive     ┌──────────────────────┐ 8. Add Tokens ┌─────────────────┐ │
│  │   MockSwapper   │◄───────────────│    SwapStack.cdc     │──────────────►│  AutoBalancer   │ │
│  │  MOET↔Yield     │   YieldTokens  │   (SwapSink)         │   to Balance  │   YieldToken    │ │
│  │                 │                └──────────────────────┘               │     Vault       │ │
│  └─────────────────┘                                                       └─────────────────┘ │
│                                                                                                │
│  RESULT: ✓ More YieldTokens in AutoBalancer  ✓ Higher Tide withdrawal balance                 │
│          ✓ Improved position health          ✓ Increased borrowing capacity                   │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────── FLOW PRICE DOWN (-30%) ────────────────────────────────────┐
│                                                                                                │
│  MockOracle.cdc: FLOW $1.00 → $0.70 (-30%)                                                    │
│  Status: UNDER-COLLATERALIZED | Trigger: Ratio < 0.95                                         │
│                                                                                                │
│  ┌─────────────────┐ 1. Price Drop  ┌──────────────────────┐ 2. Threshold   ┌─────────────────┐ │
│  │   MockOracle    │───────────────►│TidalYieldAutoBalancer│─────Breached──►│   AutoBalancer  │ │
│  │                 │                │       .cdc           │                │   (DFB.cdc)     │ │
│  │ FLOW: $0.70     │                └──────────────────────┘                │ Rebalance Needed│ │
│  └─────────────────┘                                                        └─────────────────┘ │
│                                                                                        │         │
│                                                3. Trigger Recollateralization         │         │
│                                                         │                             │         │
│                                                         ▼                             │         │
│  ┌─────────────────┐ 4. Withdraw    ┌──────────────────────┐ 5. Source     ┌─────────────────┐ │
│  │   AutoBalancer  │───────────────►│    SwapStack.cdc     │◄──────────────│  AutoBalancer   │ │
│  │  YieldToken     │  YieldTokens   │   (SwapSource)       │  YieldTokens  │    Source       │ │
│  │    Vault        │                └──────────────────────┘               │                 │ │
│  └─────────────────┘                            │                          └─────────────────┘ │
│                                                  │ 6. YieldToken → FLOW                        │
│                                                  ▼                                             │
│  ┌─────────────────┐ 7. Receive FLOW┌──────────────────────┐ 8. Add Collat ┌─────────────────┐ │
│  │   MockSwapper   │───────────────►│  TracerStrategy      │──────────────►│ TidalProtocol   │ │
│  │  Yield↔FLOW     │                │(TidalYieldStrategies │               │   Position      │ │
│  │                 │                │       .cdc)          │               │                 │ │
│  └─────────────────┘                └──────────────────────┘               └─────────────────┘ │
│                                                                                                │
│  RESULT: ✓ Fewer YieldTokens (sold for collateral)  ✓ Stabilized position health             │
│          ✓ Reduced liquidation risk                 ✓ Maintained loan safety                 │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Diagram 2: Yield Token Price Changes

```
                           YIELD TOKEN PRICE REBALANCING WITH CONTRACT INTERACTIONS

┌─────────────────────────────────── YIELD TOKEN UP (+15%) ─────────────────────────────────────┐
│                                                                                                │
│  MockOracle.cdc: YieldToken $2.00 → $2.30 (+15%)                                              │
│  Portfolio Value: $230 vs Target $200 | Trigger: Ratio > 1.05                                 │
│                                                                                                │
│  ┌─────────────────┐ 1. Price Check ┌──────────────────────┐ 2. Value Calc  ┌─────────────────┐ │
│  │   MockOracle    │───────────────►│TidalYieldAutoBalancer│─────────────►│   AutoBalancer  │ │
│  │                 │                │       .cdc           │   Portfolio   │   (DFB.cdc)     │ │
│  │YieldToken:$2.30 │                └──────────────────────┘   Over-Valued │ 100 tokens      │ │
│  └─────────────────┘                                                       │ = $230 > $200   │ │
│                                                                            └─────────────────┘ │
│                                                                                        │         │
│                                           3. Trigger Gain Capture                     │         │
│                                                         │                             │         │
│                                                         ▼                             │         │
│  ┌─────────────────┐ 4. Source      ┌──────────────────────┐ 5. Withdraw   ┌─────────────────┐ │
│  │   AutoBalancer  │───────────────►│    SwapStack.cdc     │◄──────────────│  AutoBalancer   │ │
│  │   YieldToken    │  ~13 tokens    │   (SwapSource)       │  Excess Tokens│     Source      │ │
│  │     Vault       │                └──────────────────────┘               │                 │ │
│  └─────────────────┘                            │                          └─────────────────┘ │
│                                                  │ 6. YieldToken → FLOW (~$30)                 │
│                                                  ▼                                             │
│  ┌─────────────────┐ 7. Swap to FLOW┌──────────────────────┐ 8. Enhanced   ┌─────────────────┐ │
│  │   MockSwapper   │◄───────────────│  TracerStrategy      │──────────────►│ TidalProtocol   │ │
│  │  Yield↔FLOW     │                │(TidalYieldStrategies │   Collateral  │   Position      │ │
│  │                 │                │       .cdc)          │               │                 │ │
│  └─────────────────┘                └──────────────────────┘               └─────────────────┘ │
│                                                  │                                             │
│                                                  │ 9. Borrow More MOET                        │
│                                                  ▼                                             │
│  ┌─────────────────┐ 10. Buy More   ┌──────────────────────┐ 11. Compound  ┌─────────────────┐ │
│  │   MockSwapper   │◄───────────────│    SwapStack.cdc     │──────────────►│  AutoBalancer   │ │
│  │  MOET↔Yield     │   YieldTokens  │    (SwapSink)        │   Gains       │   YieldToken    │ │
│  │                 │                └──────────────────────┘               │     Vault       │ │
│  └─────────────────┘                                                       └─────────────────┘ │
│                                                                                                │
│  RESULT: ✓ Gains captured & reinvested           ✓ More total YieldTokens acquired            │
│          ✓ Stronger collateral position          ✓ Compounded growth potential                │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────── YIELD TOKEN DOWN (-15%) ────────────────────────────────────┐
│                                                                                                │
│  MockOracle.cdc: YieldToken $2.00 → $1.70 (-15%)                                              │
│  Portfolio Value: $170 vs Target $200 | Trigger: Ratio < 0.95                                 │
│                                                                                                │
│  ┌─────────────────┐ 1. Price Drop  ┌──────────────────────┐ 2. Value Calc  ┌─────────────────┐ │
│  │   MockOracle    │───────────────►│TidalYieldAutoBalancer│─────────────►│   AutoBalancer  │ │
│  │                 │                │       .cdc           │   Portfolio   │   (DFB.cdc)     │ │
│  │YieldToken:$1.70 │                └──────────────────────┘   Under-Valued│ 100 tokens      │ │
│  └─────────────────┘                                                       │ = $170 < $200   │ │
│                                                                            └─────────────────┘ │
│                                                                                        │         │
│                                        3. Trigger Portfolio Restoration              │         │
│                                                         │                             │         │
│                                                         ▼                             │         │
│  ┌─────────────────┐ 4. More Collat ┌──────────────────────┐ 5. Issue MOET ┌─────────────────┐ │
│  │ TidalProtocol   │◄───────────────│  TracerStrategy      │◄──────────────│  TidalProtocol  │ │
│  │   Position      │   Leverage     │(TidalYieldStrategies │   (~$30 loan)  │     Pool        │ │
│  │                 │                │       .cdc)          │               │                 │ │
│  │ Collateral: FLOW│                └──────────────────────┘               └─────────────────┘ │
│  └─────────────────┘                            │                                             │
│                                                  │ 6. MOET → YieldToken (~18 tokens)          │
│                                                  ▼                                             │
│  ┌─────────────────┐ 7. Buy Tokens  ┌──────────────────────┐ 8. Restore    ┌─────────────────┐ │
│  │   MockSwapper   │◄───────────────│    SwapStack.cdc     │──────────────►│  AutoBalancer   │ │
│  │  MOET↔Yield     │                │    (SwapSink)        │   Balance     │   YieldToken    │ │
│  │                 │                └──────────────────────┘               │     Vault       │ │
│  └─────────────────┘                                                       │ Target: $200    │ │
│                                                                            └─────────────────┘ │
│                                                                                                │
│  RESULT: ✓ More YieldTokens acquired (~18 tokens)    ✓ Target portfolio value restored        │
│          ✓ Protected against further losses          ✓ Maintained optimal allocation          │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Prerequisites

1. **Set up your test environment** with the Flow emulator
2. **Deploy all contracts** including mocks
3. **Create a Tide position** using `create_tide` transaction
4. **Fund the MockSwapper** with liquidity for all token pairs

### Four Distinct Rebalancing Scenarios

The Tidal system responds to price changes in both collateral (FLOW) and yield assets (YieldToken). Here are the four scenarios you can test:

#### Setup: Record Initial State

Before testing any scenario, capture baseline metrics:

**Get your Tide ID and record initial state:**
```bash
# Get your Tide ID
flow scripts execute scripts/tidal-yield/get_tide_ids.cdc --arg Address:0xYourAddress

# Record initial balances (replace 123 with your actual Tide ID)
TIDE_ID=123
YOUR_ADDRESS=0xYourAddress

# Initial Tide balance (FLOW available for withdrawal)
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

# Initial AutoBalancer YieldToken balance  
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Initial FLOW price
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

# Initial YieldToken price
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

# Position health (you'll need to find your position ID)
POSITION_ID=456  # Different from Tide ID
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:$POSITION_ID
```

---

### SCENARIO 1: Collateral Appreciation (FLOW Price ↑)
**Test Case:** FLOW price increases → Over-collateralized → More borrowing capacity

#### Execute Test:
```bash
# 1. Increase FLOW price by 20% (e.g., $1.00 → $1.20)
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.2 \
  --signer test-account

# 2. Trigger rebalancing
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account
```

#### Verify Results:
```bash
# Check AutoBalancer balance (should INCREASE)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Check Tide withdrawable balance (should INCREASE) 
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

# Check position health (should IMPROVE)
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:$POSITION_ID
```

#### Expected Changes:
- ✅ **AutoBalancer YieldToken balance increases** (more MOET borrowed → more YieldTokens)
- ✅ **Tide withdrawable balance increases** (more FLOW available)  
- ✅ **Position health improves** (better collateralization ratio)

---

### SCENARIO 2: Collateral Depreciation (FLOW Price ↓)
**Test Case:** FLOW price decreases → Under-collateralized → Need recollateralization

#### Execute Test:
```bash
# 1. Reset to baseline first
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

# 2. Decrease FLOW price by 30% (e.g., $1.00 → $0.70)
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:0.7 \
  --signer test-account

# 3. Trigger rebalancing
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account
```

#### Verify Results:
```bash
# Check AutoBalancer balance (should DECREASE)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Check Tide balance (may decrease as collateral added)
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

# Check position health (should STABILIZE)
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:$POSITION_ID
```

#### Expected Changes:
- ✅ **AutoBalancer YieldToken balance decreases** (YieldTokens sold → FLOW for collateral)
- ✅ **Position health stabilizes** (additional collateral added)
- ✅ **Loan risk reduced** (improved collateralization ratio)

---

### SCENARIO 3: YieldToken Appreciation (YieldToken Price ↑)
**Test Case:** YieldToken price increases → Portfolio over-valued → Capture gains

#### Execute Test:
```bash
# 1. Reset FLOW price to baseline
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

# 2. Increase YieldToken price by 15% (e.g., $2.00 → $2.30)
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.30 \
  --signer test-account

# 3. Trigger rebalancing
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account
```

#### Verify Results:
```bash
# Check YieldToken price
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

# Check AutoBalancer balance (total value should rebalance)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Check position health (should improve from gains)
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:$POSITION_ID

# Check Tide balance (should increase from captured gains)
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID
```

#### Expected Changes:
- ✅ **Gains captured** from YieldToken appreciation
- ✅ **Position strengthened** with additional collateral from gains
- ✅ **More YieldTokens acquired** through reinvestment of profits

---

### SCENARIO 4: YieldToken Depreciation (YieldToken Price ↓)
**Test Case:** YieldToken price decreases → Portfolio under-valued → Restore target allocation

#### Execute Test:
```bash
# 1. Reset YieldToken to baseline first
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.0 \
  --signer test-account

# 2. Decrease YieldToken price by 15% (e.g., $2.00 → $1.70)
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:1.70 \
  --signer test-account

# 3. Trigger rebalancing
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account
```

#### Verify Results:
```bash
# Check YieldToken price
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

# Check AutoBalancer balance (should increase to restore value)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Check position health (should remain stable)
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:$POSITION_ID

# Check Tide balance
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID
```

#### Expected Changes:
- ✅ **More YieldTokens acquired** to restore target portfolio value
- ✅ **Target allocation maintained** despite price depreciation
- ✅ **Protected against further losses** through rebalancing

---

### Testing Random Market Volatility

For realistic testing, use the bump price function:

```bash
# Random FLOW price changes (±1% variance)
flow transactions send transactions/mocks/oracle/bump_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --signer test-account

# Random YieldToken price changes (±1% variance)  
flow transactions send transactions/mocks/oracle/bump_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --signer test-account

# Check if rebalancing is needed (only triggers if thresholds exceeded)
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:false \
  --signer test-account
```

### Key Metrics to Monitor

#### AutoBalancer Health
```bash
# Current YieldToken holdings in AutoBalancer
scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc

# Compare against expected value based on deposits
# Ratio should stay between 0.95 - 1.05 for healthy positions
```

#### Position Metrics
```bash
# Overall position health (collateralization ratio)
scripts/tidal-protocol/position_health.cdc

# Available balance for withdrawal from position
scripts/tidal-protocol/get_available_balance.cdc
```

#### User Balance
```bash
# Total FLOW available for withdrawal from Tide
scripts/tidal-yield/get_tide_balance.cdc

# Your account token balances
scripts/tokens/get_balance.cdc
```

### Understanding the Results

#### Successful Over-Collateralization Test
- Price increase → More borrowing capacity
- AutoBalancer YieldToken balance increases
- More MOET borrowed and converted to YieldTokens
- User's withdrawable balance increases

#### Successful Under-Collateralization Test  
- Price decrease → Position at risk
- AutoBalancer sells YieldTokens for FLOW
- Additional FLOW added as collateral to position
- Position health maintained/improved

#### Threshold Behavior
- **Automatic rebalancing** only occurs when ratios exceed ±5% thresholds
- **Manual rebalancing** (`force: true`) bypasses thresholds
- **No rebalancing** occurs if within 0.95-1.05 range and `force: false`

### Troubleshooting

#### Common Issues:
1. **"Could not borrow AutoBalancer"** - Ensure Tide ID is correct
2. **"No price set for token"** - Set initial prices for all tokens before testing
3. **"Insufficient liquidity"** - Fund MockSwapper with adequate token reserves
4. **"Position not found"** - Verify TidalProtocol position ID (different from Tide ID)

#### Debugging Commands:
```bash
# Check if oracle has price set
flow scripts execute scripts/mocks/oracle/get_price.cdc --arg String:"TOKEN_TYPE"

# Check your Tide IDs
flow scripts execute scripts/tidal-yield/get_tide_ids.cdc --arg Address:0xYourAddress

# Check supported strategies
flow scripts execute scripts/tidal-yield/get_supported_strategies.cdc
```

This testing framework allows you to validate that the rebalancing system correctly responds to market conditions while maintaining position safety and optimizing yield generation.

## Key Features

### 1. Composable Strategies
- Strategies are built by composing DeFiBlocks components
- Each strategy can have different risk/reward profiles
- New strategies can be added by implementing the Strategy interface

### 2. Automated Management
- Auto-balancers continuously monitor and optimize positions
- Reduces need for manual intervention
- Maintains target risk parameters automatically

### 3. Multi-Asset Support
- Platform designed to support multiple token types
- Strategies can be configured for different collateral types
- Flexible vault management system

### 4. Resource-Oriented Security
- Uses Cadence's resource model for secure asset management
- Tides are resources owned by users
- Automatic cleanup when positions are closed

## Important Notes

⚠️ **This is a mock implementation for development and testing purposes only. It is not intended for production use.**

The contracts include extensive mock components (MockOracle, MockSwapper, etc.) that simulate real DeFi infrastructure. In a production environment, these would be replaced with actual oracle services and DEX integrations.

## Getting Started

1. **Setup Account**: Run the setup transaction to initialize your TideManager
2. **Create Strategy**: Use create_tide to open a yield position  
3. **Manage Position**: Deposit/withdraw funds as needed
4. **Monitor Performance**: Use scripts to track your positions
5. **Close Position**: Use close_tide to exit and reclaim all funds

The platform provides a foundation for sophisticated yield farming strategies while maintaining the security and composability principles of the Cadence programming language.
