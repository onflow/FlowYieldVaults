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

### Rebalancing Flow Diagram

```
                             TIDAL REBALANCING SYSTEM
                                                                    
    ┌─────────────┐         ┌──────────────────┐         ┌─────────────────┐
    │ Mock Oracle │◄────────┤   Price Monitor  ├────────►│ AutoBalancer    │
    │             │         │                  │         │                 │
    │ FLOW: $1.00 │         │ Threshold Check: │         │ YieldToken Held │
    └─────────────┘         │ 0.95 < X < 1.05  │         │ Target Ratio    │
                            └──────────────────┘         └─────────────────┘
                                     │                            │
                                     ▼                            ▼
                            
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                        REBALANCING SCENARIOS                             │
    └─────────────────────────────────────────────────────────────────────────┘
                                     
    ┌──── OVER-COLLATERALIZED (Price ↑) ────┐    ┌─── UNDER-COLLATERALIZED (Price ↓) ───┐
    │                                       │    │                                       │
    │  FLOW Price: $1.00 → $1.20 (+20%)    │    │  FLOW Price: $1.00 → $0.70 (-30%)    │
    │  Ratio: 1.20 > 1.05 (TRIGGER!)       │    │  Ratio: 0.70 < 0.95 (TRIGGER!)       │
    │                                       │    │                                       │
    │  ┌─────────────────────────────────┐  │    │  ┌─────────────────────────────────┐  │
    │  │        REBALANCING FLOW         │  │    │  │        REBALANCING FLOW         │  │
    │  │                                 │  │    │  │                                 │  │
    │  │ 1. Higher Collateral Value      │  │    │  │ 1. Lower Collateral Value       │  │
    │  │         ▼                       │  │    │  │         ▼                       │  │
    │  │ 2. More Borrowing Capacity      │  │    │  │ 2. Position At Risk             │  │
    │  │         ▼                       │  │    │  │         ▼                       │  │
    │  │ 3. TidalProtocol Issues MOET    │  │    │  │ 3. AutoBalancer Sells YieldTkn  │  │
    │  │         ▼                       │  │    │  │         ▼                       │  │
    │  │ 4. MOET → YieldToken (Swap)     │  │    │  │ 4. YieldToken → FLOW (Swap)     │  │
    │  │         ▼                       │  │    │  │         ▼                       │  │
    │  │ 5. YieldToken → AutoBalancer    │  │    │  │ 5. FLOW → Position Collateral   │  │
    │  └─────────────────────────────────┘  │    │  └─────────────────────────────────┘  │
    │                                       │    │                                       │
    │  RESULT:                              │    │  RESULT:                              │
    │  ✓ More YieldTokens acquired          │    │  ✓ Position health improved           │
    │  ✓ Higher withdrawal balance          │    │  ✓ Liquidation risk reduced           │
    │  ✓ Increased yield generation         │    │  ✓ Stable collateral ratio            │
    └───────────────────────────────────────┘    └───────────────────────────────────────┘

                                TOKEN FLOW ARCHITECTURE
                                                       
    ┌─────────────┐    MOET     ┌─────────────┐    YieldToken   ┌─────────────────┐
    │ TidalProto  │◄───────────►│MockSwapper  │◄───────────────►│  AutoBalancer   │
    │ Position    │             │MOET↔Yield   │                 │                 │
    │             │             └─────────────┘                 │ ┌─────────────┐ │
    │ Collateral: │                   ▲                         │ │ YieldToken  │ │
    │    FLOW     │                   │                         │ │   Vault     │ │
    └─────────────┘                   │                         │ └─────────────┘ │
           ▲                          │                         └─────────────────┘
           │                          │                                   │
           │                          │                                   │
      FLOW │                     YieldToken                               │ YieldToken
           │                          │                                   │
           │                  ┌─────────────┐                            │
           └──────────────────┤MockSwapper  │◄───────────────────────────┘
                              │Yield↔FLOW   │
                              └─────────────┘
                              
    Legend:
    ────►  Token Flow Direction
    ◄───►  Bidirectional Swap
    ┌───┐  System Component
    ▲ ▼    Rebalancing Trigger

### Prerequisites

1. **Set up your test environment** with the Flow emulator
2. **Deploy all contracts** including mocks
3. **Create a Tide position** using `create_tide` transaction
4. **Fund the MockSwapper** with liquidity for all token pairs

### Step-by-Step Testing Process

#### 1. Record Initial State

Before manipulating prices, record baseline values to compare against after rebalancing.

**Get your Tide ID:**
```bash
flow scripts execute scripts/tidal-yield/get_tide_ids.cdc --arg Address:0xYourAddress
```

**Record initial balances:**
```bash
# Get initial Tide balance (FLOW available for withdrawal)
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:0xYourAddress \
  --arg UInt64:123  # Your Tide ID

# Get AutoBalancer YieldToken balance
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:123  # Your Tide ID

# Get current FLOW price from oracle
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"
```

**Check TidalProtocol position health:** 
```bash
# You'll need to find your position ID from the TidalProtocol
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:456  # Position ID (different from Tide ID)
```

#### 2. Test Over-Collateralization (Price Increase)

Increase the FLOW token price to trigger rebalancing for additional borrowing.

**Increase FLOW price by 20%:**
```bash
# If current price is 1.0, set to 1.2
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.2 \
  --signer test-account
```

**Trigger manual rebalancing:**
```bash
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:123 \
  --arg Bool:true \
  --signer test-account
```

**Observe the results:**
```bash
# Check new AutoBalancer balance (should increase)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:123

# Check new Tide balance (should increase)
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:0xYourAddress \
  --arg UInt64:123

# Check position health (should improve)
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:456
```

**Expected Changes:**
- ✅ **AutoBalancer YieldToken balance increases** (more yield tokens acquired)
- ✅ **Tide withdrawable balance increases** (more FLOW available)
- ✅ **Position health improves** (better collateralization ratio)
- ✅ **More MOET borrowed** against the higher collateral value

#### 3. Test Under-Collateralization (Price Decrease)

Decrease the FLOW token price to trigger recollateralization.

**Decrease FLOW price by 30%:**
```bash
# Set price lower than original (e.g., from 1.0 to 0.7)
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:0.7 \
  --signer test-account
```

**Trigger rebalancing:**
```bash
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:123 \
  --arg Bool:true \
  --signer test-account
```

**Observe the results:**
```bash
# Check AutoBalancer balance (should decrease)
flow scripts execute scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:123

# Check Tide balance 
flow scripts execute scripts/tidal-yield/get_tide_balance.cdc \
  --arg Address:0xYourAddress \
  --arg UInt64:123

# Check position health
flow scripts execute scripts/tidal-protocol/position_health.cdc \
  --arg UInt64:456
```

**Expected Changes:**
- ✅ **AutoBalancer YieldToken balance decreases** (tokens sold for collateral)
- ✅ **Position health stabilizes** (collateral added to maintain ratio)
- ✅ **Loan risk reduced** through additional collateralization

#### 4. Test Random Price Fluctuations

Use the bump price function to simulate market volatility.

**Random price changes:**
```bash
# Bump price randomly within ±1% variance
flow transactions send transactions/mocks/oracle/bump_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --signer test-account

# Check new price
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

# Force rebalancing if needed
flow transactions send transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:123 \
  --arg Bool:false \  # Only rebalance if thresholds exceeded
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
