# FlowVaults Smart Contracts

FlowVaults is a yield farming platform built on the Flow blockchain using [Cadence](https://cadence-lang.org). The platform enables users to deposit tokens to supported DeFi strategies such as collateralized borrowing via FlowALP's Active Lending Platform. FlowVaults aims to support yield-generating strategies, automatically optimizing returns through [DeFi Actions](https://developers.flow.com/blockchain-development-tutorials/forte/flow-actions) components and auto-balancing mechanisms.

## System Architecture

The FlowVaults platform consists of several interconnected components:

### Core Contracts

#### 1. FlowVaults.cdc - Main Platform Contract

The main contract that orchestrates the entire yield farming system:

- **Strategy Interface**: Defines yield-generating strategies that can deposit/withdraw tokens
- **StrategyComposer**: Creates and manages different strategy implementations
- **StrategyFactory**: Manages multiple strategy composers and creates strategy instances
- **Tide Resource**: Represents a user's position in a specific strategy
- **TideManager**: Manages multiple Tide positions for a user account

#### 2. FlowVaultsStrategies.cdc - Strategy Implementations

Implements specific yield strategies:

- **TracerStrategy**: A strategy that uses FlowALP lending positions with auto-balancing
- **TracerStrategyComposer**: Creates TracerStrategy instances with complex DeFi Actions stacking
- **StrategyComposerIssuer**: Controls access to strategy composer creation

#### 3. FlowVaultsAutoBalancers.cdc - Auto-Balancing System

Manages automated rebalancing of positions:

- Stores AutoBalancer instances in contract storage
- Automatically rebalances positions when they move outside configured thresholds
- Cleans up AutoBalancers when strategies are closed

### Token Contracts

#### YieldToken.cdc & MOET.cdc

Mock FungibleToken implementations representing:

- **YieldToken**: Receipt tokens for yield-bearing positions
- **MOET**: FlowALP's synthetic stablecoin

### Mock Infrastructure

#### MockOracle.cdc

- Provides price feeds for testing and demonstrations
- Supports price manipulation for testing scenarios
- Implements DeFiActions.PriceOracle interface

#### MockSwapper.cdc

- Simulates token swapping functionality
- Uses oracle prices to calculate swap rates
- Manages liquidity connectors for different token pairs

### Contract Deployments

#### Testnet
| Asset Name | Cadence Address | Cadence Contract Name | EVM |
|---|---|---|---|
| FlowActions | 0xd27920b6384e2a78 | DeFiActions | TBD |
| FlowALP | 0xd27920b6384e2a78 | FlowALP | TBD |
| FlowVaults | 0xd27920b6384e2a78 | FlowVaults | TBD |
| FlowVaultsStrategies | 0xd27920b6384e2a78 | FlowVaultsStrategies | TBD |
| MOET | 0xd27920b6384e2a78 | MOET | 0x51f5cc5f50afb81e8f23c926080fa38c3024b238 |
| USDC | 0xdfc20aee650fcbdf | EVMVMBridgedToken_d431955d55a99ef69beb96ba34718d0f9fbc91b1 | 0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1 |
| wBTC | 0xdfc20aee650fcbdf | EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6 | 0x208d09d2a6Dd176e3e95b3F0DE172A7471C5B2d6 |
| wETH | 0xdfc20aee650fcbdf | EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848 | 0x059A77239daFa770977DD9f1E98632C3E4559848 |
| mUSDC (ERC4626) | 0xdfc20aee650fcbdf | EVMVMBridgedToken_4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95 | 0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95 |

#### Mainnet
| Contract Name | Cadence | EVM |
|---|---|---|
|  | TBD | TBD |
|  | TBD | TBD |

## How the System Works

Below is an overview of the initial prototype Tracer Strategy in the broader context of FlowALP and the FlowVaults platform.

### 1. Strategy Architecture

The TracerStrategy demonstrates the power of DeFi Actions composition:

```
User Deposit (FLOW) → FlowALP Position → MOET Issuance → Swap to YieldToken → AutoBalancer
                                               ↑
                                         YieldToken → Swap to FLOW → Recollateralize Position
```

### 2. Auto-Balancing Mechanism

- AutoBalancers monitor the value of deposits vs. current token holdings
- When balance moves outside configured thresholds (±5%), automatic rebalancing occurs
- Excess value flows into position recollateralization
- Insufficient value triggers position adjustments

### 3. DeFi Actions Integration

The system heavily uses [DeFi Actions](https://developers.flow.com/blockchain-development-tutorials/forte/flow-actions) components:

- **Sinks**: Accept token deposits
- **Sources**: Provide token withdrawals
- **Swappers**: Handle token conversions
- **AutoBalancers**: Maintain optimal position ratios

## User Interactions

### Scripts (Read Operations)

[Cadence Scripts](https://developers.flow.com/build/cadence/basics/scripts) are written in Cadence and take advantage of [Native Data Availability](https://developers.flow.com/blockchain-development-tutorials/cadence/cadence-advantages/native-data-availibility-with-cadence-scripts) read and format any public data on the blockchain in the way the developer needs it, without relying on pre-existing view functions in the contract.

#### `scripts/flow-vaults/get_tide_ids.cdc`

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

[Cadence Transactions](https://cadence-lang.org/docs/language/transactions) are written in Cadence and allow you to [compose](https://developers.flow.com/blockchain-development-tutorials/cadence/cadence-advantages/compose-with-cadence-transactions) several function calls to several contracts within a single user approval.

#### Setup

```cadence
// Setup user account for FlowVaults platform
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

`flow.json` contains network configurations and contract deployment settings. It is created and managed with the [Flow CLI](https://developers.flow.com/build/tools/flow-cli).

## Rebalancing and Recollateralizing

The FlowVaults platform implements sophisticated automatic rebalancing and recollateralizing mechanisms to maintain healthy loan positions and optimize yield generation.

**Important Distinction:** The system has TWO different rebalancing mechanisms:

1. **AutoBalancer Rebalancing** (DFB): Maintains optimal ratio between YieldToken holdings and expected deposit value
2. **Position Rebalancing** (FlowALP): Maintains healthy collateralization ratios for lending positions

These work together but serve different purposes and can trigger independently based on market conditions.

### How Auto-Balancing Works

Each TracerStrategy includes an AutoBalancer with configured thresholds:

- **Lower Threshold: 0.95** (5% below target)
- **Upper Threshold: 1.05** (5% above target)

The AutoBalancer continuously monitors the **value ratio** between:

- Current YieldToken holdings (actual balance)
- Expected value based on initial deposits (target balance)

### Rebalancing Scenarios

#### 1. Overflown AutoBalancer Value (Upper Threshold Exceeded)

**When:** Current YieldToken value > 105% historical value of deposits
**Cause:** YieldToken price has increased OR position became over-collateralized leading to excess token holdings
**Action:** AutoBalancer deposits excess YieldToken to the rebalanceSink, swapping to FLOW and recollateralizing the FlowALP position.

**Automated Flow:**

```
YieldToken (excess) → Swap to FLOW → Deposit to FlowALP Position (recollateralization)
```

**Result:**

- Excess value moved from YieldToken holdings back to collateral
- Position health improved through additional collateralization
- Maintained optimal balance between yield tokens and position safety

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
let autoBalancer = FlowVaultsAutoBalancers._initNewAutoBalancer(
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

   - User deposits FLOW → FlowALP Position
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

**Transaction:** `transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc`

```cadence
// Force rebalancing regardless of thresholds
transaction rebalance_auto_balancer_by_id(id: UInt64, force: Bool)
```

**Parameters:**

- `id`: Tide ID associated with the AutoBalancer
- `force`: Whether to bypass threshold checks

### Monitoring Rebalancing

#### Check AutoBalancer Balance

**Script:** `scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc`

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

### Integration with DeFi Actions

The rebalancing system leverages DeFi Actions components:

- **Sinks**: Route tokens into rebalancing flows
- **Sources**: Extract tokens for rebalancing operations
- **Swappers**: Convert between token types (MOET ↔ YieldToken ↔ FLOW)
- **Oracle**: Provides price data for value calculations
- **AutoBalancer**: Central coordination of rebalancing logic

This creates a fully automated yield farming system that adapts to market conditions while maintaining position safety.

## Interest Rate System

The FlowALP implements a sophisticated interest rate system that governs borrowing costs and lending yields. This system is fundamental to the protocol's economics and affects all lending positions.

### How Interest Rates Work

#### 1. Interest Rate Calculation

Interest rates are determined dynamically based on supply and demand:

- **Debit Interest Rate**: The rate charged on borrowed tokens
- **Credit Interest Rate**: The rate earned on deposited tokens
- **Utilization-Based**: Rates adjust based on the ratio of borrowed to supplied tokens

#### 2. Interest Curves

The protocol uses `InterestCurve` implementations to calculate rates:

```cadence
// Simple example - in production, curves would be more sophisticated
access(all) struct SimpleInterestCurve: InterestCurve {
    access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64 {
        // Returns interest rate based on utilization ratio
        // Higher utilization = higher rates
        let utilizationRatio = debitBalance / creditBalance
        return baseRate + (utilizationRatio * rateSlope)
    }
}
```

#### 3. Compound Interest Implementation

Interest compounds continuously using per-second calculations:

- **Per-Second Rates**: Yearly rates converted to per-second multipliers
- **Interest Indices**: Track cumulative interest over time
- **Automatic Compounding**: Interest accrues every second without manual updates

### Interest Index System

#### Scaled Balances

The protocol uses "scaled balances" for efficiency:

```
Scaled Balance = True Balance / Interest Index
True Balance = Scaled Balance × Interest Index
```

**Benefits:**

- No need to update every position when interest accrues
- Only update when deposits/withdrawals occur
- Interest automatically compounds through index growth

#### Interest Index Updates

```cadence
// Interest index compounds over time
newIndex = oldIndex × (perSecondRate ^ elapsedSeconds)
```

### Interest Rate Types

#### Credit Interest (Lender Earnings)

- **Earned by**: Token depositors (lenders)
- **Rate Calculation**: `(debitIncome - insuranceReserve) / totalCreditBalance`
- **Insurance Deduction**: 0.1% of credit balance reserved for protocol security
- **Distribution**: Paid to all credit positions proportionally

#### Debit Interest (Borrower Costs)

- **Paid by**: Token borrowers
- **Rate Determination**: Set by interest curve based on utilization
- **Market Driven**: High demand = higher rates
- **Risk Adjusted**: Riskier assets typically have higher rates

### Interest Rate Parameters

#### Per-Token Configuration

Each supported token has individual interest parameters:

```cadence
// When adding a new token to the pool
pool.addSupportedToken(
    tokenType: Type<@FlowToken.Vault>(),
    collateralFactor: 0.8,        // 80% of value usable as collateral
    borrowFactor: 1.0,            // No additional risk adjustment
    interestCurve: MyInterestCurve(),  // Custom rate calculation
    depositRate: 1000000.0,       // Rate limiting for deposits
    depositCapacityCap: 1000000.0 // Maximum deposit capacity
)
```

#### Risk Factors

- **Collateral Factor**: Percentage of token value that can be borrowed against
- **Borrow Factor**: Additional risk adjustment for debt calculations
- **Interest Curve**: Algorithm determining base interest rates

### How Interest Affects Positions

#### Position Health Impact

Interest accrual affects position health over time:

```
Health = Effective Collateral / Effective Debt

// As debt interest accrues:
// - Effective Debt increases
// - Position health decreases
// - May trigger rebalancing or liquidation
```

#### Automatic Rebalancing with Interest

The rebalancing system accounts for interest:

1. **Interest Accrual**: Debt grows, collateral may earn yield
2. **Health Monitoring**: System checks if health falls below thresholds
3. **Automatic Adjustment**: Rebalancing triggered to maintain target health
4. **Compound Effect**: Interest earnings can be reinvested automatically

### Interest Rate Examples

#### High Utilization Scenario

```
Total Credit Balance: 1,000,000 FLOW
Total Debit Balance: 800,000 FLOW
Utilization: 80%

// High utilization leads to:
Debit Interest Rate: 8% APY
Credit Interest Rate: 6.4% APY (after insurance deduction)
```

#### Low Utilization Scenario

```
Total Credit Balance: 1,000,000 FLOW
Total Debit Balance: 200,000 FLOW
Utilization: 20%

// Low utilization leads to:
Debit Interest Rate: 2% APY
Credit Interest Rate: 0.36% APY (after insurance deduction)
```

### Monitoring Interest Rates

#### For Position Holders

- **Borrow Costs**: Monitor debit interest on borrowed amounts
- **Earning Rates**: Track credit interest on deposited collateral
- **Health Impact**: Watch how interest affects position health over time

#### For Protocol Governance

- **Rate Optimization**: Adjust interest curves based on market conditions
- **Risk Management**: Monitor utilization ratios and adjust parameters
- **Protocol Revenue**: Track insurance reserves and protocol fees

### Interest Rate Security

#### Insurance Mechanism

- **Reserve Fund**: 0.1% of credit balance reserved for protocol security
- **Liquidation Protection**: Reserves help cover bad debt from liquidations
- **Rate Stability**: Insurance provides buffer for rate calculations

#### Risk Management

- **Dynamic Rates**: Automatically adjust to market conditions
- **Utilization Caps**: Prevent over-borrowing through rate increases
- **Oracle Integration**: Interest calculations use real-time price data

The interest rate system is designed to:

1. **Balance Supply/Demand**: Higher rates when utilization is high
2. **Incentivize Stability**: Rewards for providing liquidity during high demand
3. **Manage Risk**: Insurance reserves and dynamic adjustments protect the protocol
4. **Enable Automation**: Continuous compounding without manual intervention

This interest system is what enables the FlowALP to function as a sustainable lending platform while providing the foundation for complex yield farming strategies built on top.

## FlowALP Loan Health Mechanism

The FlowALP implements a sophisticated loan health system that determines borrowing capacity, monitors position safety, and prevents liquidations. This system is fundamental to how the TracerStrategy calculates how much can be borrowed against a user's initial collateral position.

### Key Definitions

Before diving into the mechanics, it's important to understand the core terminology used throughout the FlowALP loan system:

#### Position-Related Terms

- **Position**: A lending/borrowing account that holds collateral and debt across multiple token types
- **Position ID (pid)**: Unique identifier for each lending position in the protocol
- **Position Health**: Numerical ratio representing the safety of a lending position (Effective Collateral ÷ Effective Debt)
- **Balance Direction**: Whether a token balance is Credit (collateral/deposit) or Debit (borrowed/debt)

#### Value Calculation Terms

- **Effective Collateral**: Total USD value of all collateral deposits, adjusted by their respective Collateral Factors
- **Effective Debt**: Total USD value of all borrowed amounts, adjusted by their respective Borrow Factors
- **Oracle Price**: Real-time market price of tokens provided by price oracles (e.g., FLOW = $1.00, YieldToken = $2.00)
- **Token Value**: Raw USD value of token amount (Token Amount × Oracle Price)

#### Risk Parameter Terms

- **Collateral Factor**: Percentage (0.0-1.0) of a token's value that counts toward borrowing capacity (e.g., 0.8 = 80%)
- **Borrow Factor**: Risk adjustment (0.0-1.0) applied to borrowed amounts for additional safety margins
- **Target Health**: Optimal health ratio (default: 1.3) that the protocol maintains through automatic rebalancing
- **Minimum Health**: Liquidation threshold (default: 1.1) below which positions become unsafe
- **Maximum Health**: Upper bound that triggers automatic draw-down of excess collateral

#### Interest and Balance Terms

- **Scaled Balance**: Stored balance amount that doesn't change with interest accrual
- **True Balance**: Actual current balance including accumulated interest (Scaled Balance × Interest Index)
- **Interest Index**: Compound multiplier that tracks accumulated interest over time
- **Token State**: Global state tracking interest rates, indices, and lending parameters for each token type

#### System Operation Terms

- **Liquidation**: Forced closure of unhealthy positions to protect the protocol and lenders
- **Rebalancing**: Automatic adjustment of positions to maintain target health ratios
- **Top-Up Source**: Optional funding source that can add collateral to prevent liquidation
- **Draw-Down Sink**: Destination for excess funds when positions become over-collateralized

### Core Health Calculation

The protocol calculates position health using the formula:

```
Position Health = Effective Collateral / Effective Debt
```

#### Health Computation Function

```cadence
// From FlowALP.cdc
access(all) fun healthComputation(effectiveCollateral: UFix64, effectiveDebt: UFix64): UFix64 {
    if effectiveCollateral == 0.0 {
        return 0.0
    } else if effectiveDebt == 0.0 {
        return UFix64.max  // Infinite health - no debt
    } else {
        return effectiveCollateral / effectiveDebt
    }
}
```

### Effective Collateral and Effective Debt

#### Effective Collateral Calculation

For each token type in a position:

```
Token Value = Token Amount × Oracle Price
Effective Collateral += Token Value × Collateral Factor
```

#### Effective Debt Calculation

For each borrowed token type:

```
Token Value = Token Amount × Oracle Price
Effective Debt += Token Value ÷ Borrow Factor
```

### Risk Parameters

#### Collateral Factor

- **Definition**: Percentage of token value that can be used as collateral
- **Range**: 0.0 to 1.0 (0% to 100%)
- **Purpose**: Manages risk based on token volatility and liquidity
- **Example**: FLOW with 0.8 collateral factor means 80% of FLOW value counts toward borrowing capacity

#### Borrow Factor

- **Definition**: Risk adjustment applied to borrowed amounts
- **Range**: 0.0 to 1.0 (0% to 100%)
- **Purpose**: Additional safety margin for high-risk borrowing scenarios
- **Effect**: Lower borrow factor = higher effective debt for same borrowed amount

### Health Thresholds

#### Target Health

- **Default Value**: 1.3 (130% collateralization)
- **Purpose**: Optimal health level the protocol maintains through rebalancing
- **Getter**: `getTargetHealth()`
- **Setter**: `setTargetHealth(targetHealth: UFix64)` (governance only)

#### Minimum Health

- **Default Value**: 1.1 (110% collateralization)
- **Purpose**: Liquidation threshold - positions below this health are at risk
- **Getter**: `getMinHealth()`
- **Setter**: `setMinHealth(minHealth: UFix64)` (governance only)

#### Maximum Health

- **Purpose**: Upper bound for automatic rebalancing
- **Behavior**: Positions above this trigger draw-down to target health

### Borrowing Capacity Calculation

When a user deposits collateral, the protocol calculates maximum borrowing capacity:

```cadence
// Simplified borrowing capacity calculation
let tokenValue = collateralAmount × oraclePrice
let effectiveCollateral = tokenValue × collateralFactor
let maxBorrowableValue = effectiveCollateral ÷ targetHealth
let maxBorrowableTokens = maxBorrowableValue × borrowFactor ÷ borrowTokenPrice
```

#### Real Example with TracerStrategy

1. **User deposits 100 FLOW at $1.00 each**
2. **FLOW collateral factor: 0.8 (80%)**
3. **Target health: 1.3 (130%)**
4. **MOET borrow factor: 1.0 (100%)**

```
Token Value = 100 FLOW × $1.00 = $100
Effective Collateral = $100 × 0.8 = $80
Max Borrowable Value = $80 ÷ 1.3 = $61.54
Max MOET Borrowable = $61.54 × 1.0 ÷ $1.00 = 61.54 MOET
```

### Scaled Balance System

The protocol uses **scaled balances** for efficient interest calculations:

#### True vs Scaled Balance

```cadence
// Convert scaled balance to actual balance
fun scaledBalanceToTrueBalance(scaledBalance: UFix64, interestIndex: UInt64): UFix64 {
    let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
    return scaledBalance * indexMultiplier
}
```

#### Interest Index Compounding

```cadence
// Interest compounds continuously
newIndex = oldIndex × (perSecondRate ^ elapsedSeconds)
```

### Position Health Monitoring

#### Balance Sheet Structure

```cadence
access(all) struct BalanceSheet {
    access(all) let effectiveCollateral: UFix64
    access(all) let effectiveDebt: UFix64
    access(all) let health: UFix64
}
```

#### Health Calculation for Multi-Token Positions

```cadence
access(all) fun positionHealth(pid: UInt64): UFix64 {
    var effectiveCollateral = 0.0
    var effectiveDebt = 0.0

    for type in position.balances.keys {
        let balance = position.balances[type]!
        let tokenState = self.tokenState(type: type)
        let tokenPrice = self.priceOracle.price(ofToken: type)!

        if balance.direction == BalanceDirection.Credit {
            // Collateral calculation
            let trueBalance = scaledBalanceToTrueBalance(
                scaledBalance: balance.scaledBalance,
                interestIndex: tokenState.creditInterestIndex
            )
            let value = tokenPrice * trueBalance
            effectiveCollateral += (value * self.collateralFactor[type]!)

        } else {
            // Debt calculation
            let trueBalance = scaledBalanceToTrueBalance(
                scaledBalance: balance.scaledBalance,
                interestIndex: tokenState.debitInterestIndex
            )
            let value = tokenPrice * trueBalance
            effectiveDebt += (value / self.borrowFactor[type]!)
        }
    }

    return healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
}
```

### Available Funds Calculations

#### Funds Available Above Target Health

The protocol calculates how much can be withdrawn while maintaining target health:

```cadence
access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64
```

**Logic:**

1. Calculate current effective collateral and debt
2. Determine maximum debt increase that maintains target health
3. Convert to token amount using price oracle and borrow factor

#### Funds Required for Target Health

Calculates additional deposits needed to reach target health:

```cadence
access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64
```

### Health-Based Operations

#### Withdrawal Validation

```cadence
access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UFix64
```

- Returns projected health after withdrawal
- Values below 1.0 indicate withdrawal would fail
- Used to prevent unhealthy withdrawals

#### Deposit Impact

```cadence
access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix64
```

- Calculates health improvement from deposits
- Accounts for debt payoff vs collateral increase

### Automatic Rebalancing Integration

#### Position Health Monitoring

The protocol continuously monitors position health and triggers rebalancing:

```cadence
// From rebalancePosition function
let balanceSheet = self.positionBalanceSheet(pid: pid)

if balanceSheet.health < position.targetHealth {
    // Under-collateralized: need more collateral or debt payoff
    // Trigger top-up from repayment source

} else if balanceSheet.health > position.targetHealth {
    // Over-collateralized: can borrow more or withdraw excess
    // Trigger draw-down to sink
}
```

#### TracerStrategy Health Management

The TracerStrategy leverages this health system:

1. **Initial Position**: Deposits FLOW, borrows MOET at target health (1.3)
2. **Health Monitoring**: AutoBalancer tracks YieldToken value vs expected value
3. **Price Changes**: Oracle price updates affect position health
4. **Automatic Rebalancing**: System maintains health within target range

### Liquidation Protection

#### Minimum Health Enforcement

- Positions below `minHealth` (1.1) trigger automatic intervention
- System attempts to use `repaymentSource` before liquidation
- Multiple rebalancing attempts before declaring position unhealthy

#### Top-Up Source Integration

```cadence
// Position structure includes automatic top-up capability
access(EImplementation) var topUpSource: {DeFiActions.Source}?
```

### Oracle Price Integration

#### Real-Time Health Updates

```cadence
// All health calculations use live oracle prices
let tokenPrice = self.priceOracle.price(ofToken: type)!
let value = tokenPrice * trueBalance
```

#### Multi-Token Support

- Each token type has individual collateral and borrow factors
- Oracle provides prices in terms of default token (typically FLOW)
- Health calculations aggregate across all position tokens

### Key Features for Yield Strategies

#### Dynamic Borrowing Capacity

- Borrowing capacity increases with collateral value appreciation
- Automatic recognition of additional borrowing room
- Enables strategies to leverage favorable market conditions

#### Interest-Aware Calculations

- All balance calculations include accrued interest
- Compound interest affects both collateral and debt over time
- Health automatically adjusts for interest accumulation

#### Multi-Asset Position Management

- Single position can hold multiple collateral and debt types
- Cross-collateralization enables complex strategies
- Unified health calculation across all assets

This comprehensive loan health system enables the FlowALP to safely support leveraged yield farming strategies while maintaining strict risk management and protecting user funds from liquidation through automated rebalancing mechanisms.

## Testing Rebalancing

This section provides a step-by-step guide to test rebalancing functionality in the mock environment by manipulating collateral prices and observing the automatic rebalancing effects.

### Diagram 1: Collateral Token (FLOW) Price Changes

                            COLLATERAL PRICE REBALANCING WITH CONTRACT INTERACTIONS

## Collateral Token Price goes up

![COLLATERAL PRICE UP](./1-flow-vaults-diagram.png)

## Collateral Token Price goes down

![COLLATERAL PRICE DOWN](./2-flow-vaults-diagram.png)

### Yield Token Price Changes

                           YIELD TOKEN PRICE REBALANCING WITH CONTRACT INTERACTIONS

![YIELD TOKEN AUTOBALANCER](./3-flow-vaults-diagram.png)

The AutoBalancer deposits to a Sink, withdrawing YIELD from the nested Vault. The inner Sink is a SwapSink that swaps from YIELD to FLOW and then deposits to a PositionSink. The deposited FLOW makes its way to the Pool and recollateralizes the position, increasing the position's size. The protocol then pushes the surplus value to its drawDownSink. That drawDownSink is also a SwapSink that takes the deposited MOET, swaps it to YIELD and then deposits the swapped tokens to the AutoBalancerSink. That sink then finally deposits the YIELD to the AutoBalancer on which the rebalance was initially called, increasing the valueOfDeposits and closing the loop.

YIELD TOKEN DOWN Scenario not currently supported

### Prerequisites

1. **Set up your test environment** with the Flow emulator
2. **Deploy all contracts** including mocks
3. **Create a Tide position** using `create_tide` transaction
4. **Fund the MockSwapper** with liquidity for all token pairs

## Independent Testing Scenarios for Junior Engineers

Each scenario below is completely self-contained and can be run independently. You only need to ensure that **contracts are already deployed** to the Flow emulator. Each scenario handles its own setup, execution, and verification.

**Prerequisites:** Flow emulator running with all FlowVaults contracts deployed.

---

## SCENARIO 1: Collateral Appreciates (FLOW Price Increases)

**What happens:** FLOW price increases → Position becomes over-collateralized → AutoBalancer may rebalance if YieldToken holdings exceed threshold

**Expected Outcome:** If AutoBalancer triggers: fewer YieldTokens (sold for collateral), stronger position health

### Complete Self-Contained Test:

```bash
#!/bin/bash
echo "=== SCENARIO 1: FLOW PRICE INCREASE ==="
echo "Setting up independent test environment..."

# Variables for this scenario
export YOUR_ADDRESS="0xf8d6e0586b0a20c7"  # Default test account
export INITIAL_DEPOSIT=100.0

# Step 1: Setup account for FlowVaults platform
echo "Setting up FlowVaults account..."
flow transactions send cadence/transactions/flow-vaults/setup.cdc \
  --signer test-account

# Step 2: Setup token vaults
echo "Setting up token vaults..."
flow transactions send cadence/transactions/moet/setup_vault.cdc \
  --signer test-account

flow transactions send cadence/transactions/yield-token/setup_vault.cdc \
  --signer test-account

# Step 3: Initialize token prices
echo "Setting initial token prices..."
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  "A.0ae53cb6e3f42a79.FlowToken.Vault" \
  1.0 \
  --signer test-account

flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  "A.045a1763c93006ca.YieldToken.Vault" \
  2.0 \
  --signer test-account

flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  "A.045a1763c93006ca.MOET.Vault" \
  1.0 \
  --signer test-account

# Step 4: Fund MockSwapper with liquidity
echo "Funding MockSwapper with liquidity..."
flow transactions send cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
  "/storage/flowTokenVault" \
  --signer test-account

flow transactions send cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
  "/storage/moetTokenVault_0x045a1763c93006ca" \
  --signer test-account

flow transactions send cadence/transactions/mocks/swapper/set_liquidity_connector.cdc \
  "/storage/yieldTokenVault_0x045a1763c93006ca" \
  --signer test-account

# Step 5: Create Tide position
echo "Creating Tide position with $INITIAL_DEPOSIT FLOW..."
flow transactions send cadence/transactions/tidal-yield/create_tide.cdc \
  "A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy" \
  "A.0ae53cb6e3f42a79.FlowToken.Vault" \
  $INITIAL_DEPOSIT \
  --signer test-account

# Step 6: Get the Tide ID
echo "Getting Tide ID..."
TIDE_ID=$(flow scripts execute cadence/scripts/flow-vaults/get_tide_ids.cdc \
  $YOUR_ADDRESS | grep -o '[0-9]\+' | head -1)
echo "Tide ID: $TIDE_ID"

# Step 7: Record baseline metrics
echo "=== RECORDING BASELINE METRICS ==="
echo "Initial FLOW Price:"
flow scripts execute cadence/scripts/mocks/oracle/get_price.cdc \
  "A.0ae53cb6e3f42a79.FlowToken.Vault"

echo "Initial YieldToken Price:"
flow scripts execute cadence/scripts/mocks/oracle/get_price.cdc \
  "A.045a1763c93006ca.YieldToken.Vault"

echo "Initial Tide Balance:"
flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  $YOUR_ADDRESS $TIDE_ID

echo "Initial AutoBalancer Balance:"
flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  $TIDE_ID

# Step 8: Execute the test - Increase FLOW price by 20%
echo "=== EXECUTING TEST: FLOW PRICE INCREASE ==="
echo "Setting FLOW price from $1.00 to $1.20 (+20%)"
flow transactions send cadence/transactions/mocks/oracle/set_price.cdc \
  "A.0ae53cb6e3f42a79.FlowToken.Vault" \
  1.2 \
  --signer test-account

echo "Confirming new FLOW price:"
flow scripts execute cadence/scripts/mocks/oracle/get_price.cdc \
  "A.0ae53cb6e3f42a79.FlowToken.Vault"

# Step 9: Trigger rebalancing
echo "Triggering rebalancing..."
flow transactions send cadence/transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc \
  $TIDE_ID true \
  --signer test-account

flow transactions send cadence/transactions/flow-alp/pool-management/rebalance_position.cdc \
  $TIDE_ID true \
  --signer test-account

# Step 10: Verify results
echo "=== VERIFYING RESULTS ==="
echo "New AutoBalancer Balance (should be HIGHER):"
flow scripts execute cadence/scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  $TIDE_ID

echo "New Tide Balance):"
flow scripts execute cadence/scripts/flow-vaults/get_tide_balance.cdc \
  $YOUR_ADDRESS $TIDE_ID

echo "SCENARIO 1 COMPLETE!"
echo "Expected Results:"
echo "- If AutoBalancer triggers: YieldToken balance may DECREASE (sold for collateral)"
echo "- Position health should IMPROVE from additional collateral"
echo "- FLOW price increase may trigger AutoBalancer rebalanceSink if YieldToken value exceeds threshold"
```

**What You Should See:**

- **Position health improves** (higher FLOW collateral value)
- **AutoBalancer may trigger rebalanceSink** if YieldToken holdings exceed threshold
- **If rebalancing occurs: YieldToken balance decreases** (sold for additional collateral)

---

## SCENARIO 2: Collateral Depreciates (FLOW Price Decreases)

**What happens:** FLOW price decreases → Position becomes under-collateralized → Position may use topUpSource (AutoBalancer) to add collateral

**Expected Outcome:** Position health stabilized through topUpSource mechanism, may reduce YieldToken holdings

### Complete Self-Contained Test:

```bash
#!/bin/bash
echo "=== SCENARIO 2: FLOW PRICE DECREASE ==="
echo "Setting up independent test environment..."

# Variables for this scenario
export YOUR_ADDRESS="0xf8d6e0586b0a20c7"  # Default test account
export INITIAL_DEPOSIT=100.0

# Step 1: Setup account for FlowVaults platform
echo "Setting up FlowVaults account..."
flow transactions send transactions/flow-vaults/setup.cdc \
  --signer test-account

# Step 2: Setup token vaults
echo "Setting up token vaults..."
flow transactions send transactions/moet/setup_vault.cdc \
  --signer test-account

flow transactions send transactions/yield-token/setup_vault.cdc \
  --signer test-account

# Step 3: Initialize token prices
echo "Setting initial token prices..."
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

# Step 4: Fund MockSwapper with liquidity
echo "Funding MockSwapper with liquidity..."
flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

# Step 5: Create Tide position
echo "Creating Tide position with $INITIAL_DEPOSIT FLOW..."
flow transactions send transactions/flow-vaults/create_tide.cdc \
  --arg String:"tracer" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:$INITIAL_DEPOSIT \
  --signer test-account

# Step 6: Get the Tide ID
echo "Getting Tide ID..."
TIDE_ID=$(flow scripts execute scripts/flow-vaults/get_tide_ids.cdc \
  --arg Address:$YOUR_ADDRESS | grep -o '[0-9]\+' | head -1)
echo "Tide ID: $TIDE_ID"

# Step 7: Record baseline metrics
echo "=== RECORDING BASELINE METRICS ==="
echo "Initial FLOW Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

echo "Initial YieldToken Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

echo "Initial Tide Balance:"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "Initial AutoBalancer Balance:"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Step 8: Execute the test - Decrease FLOW price by 30%
echo "=== EXECUTING TEST: FLOW PRICE DECREASE ==="
echo "Setting FLOW price from $1.00 to $0.70 (-30%)"
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:0.7 \
  --signer test-account

echo "Confirming new FLOW price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

# Step 9: Trigger rebalancing
echo "Triggering recollateralization..."
flow transactions send transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account

# Step 10: Verify results
echo "=== VERIFYING RESULTS ==="
echo "New AutoBalancer Balance (should be LOWER):"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

echo "New Tide Balance (may be lower due to collateral needs):"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "SCENARIO 2 COMPLETE!"
echo "Expected Results:"
echo "- Position may use topUpSource to add collateral (if configured)"
echo "- AutoBalancer balance may DECREASE if used as topUpSource"
echo "- Position health stabilized through topUpSource mechanism"
```

**What You Should See:**

- **Position health at risk** (lower FLOW collateral value)
- **May trigger topUpSource mechanism** (AutoBalancer provides collateral if configured)
- **AutoBalancer balance may decrease** if used as topUpSource for position health

---

## SCENARIO 3: YieldToken Appreciates (YieldToken Price Increases)

**What happens:** YieldToken price increases → AutoBalancer portfolio over-valued → Sells excess YieldTokens → Moves gains to position collateral

**Expected Outcome:** Gains captured and transferred to collateral, AutoBalancer rebalanced, stronger position health

### Complete Self-Contained Test:

```bash
#!/bin/bash
echo "=== SCENARIO 3: YIELD TOKEN PRICE INCREASE ==="
echo "Setting up independent test environment..."

# Variables for this scenario
export YOUR_ADDRESS="0xf8d6e0586b0a20c7"  # Default test account
export INITIAL_DEPOSIT=100.0

# Step 1: Setup account for FlowVaults platform
echo "Setting up FlowVaults account..."
flow transactions send transactions/flow-vaults/setup.cdc \
  --signer test-account

# Step 2: Setup token vaults
echo "Setting up token vaults..."
flow transactions send transactions/moet/setup_vault.cdc \
  --signer test-account

flow transactions send transactions/yield-token/setup_vault.cdc \
  --signer test-account

# Step 3: Initialize token prices
echo "Setting initial token prices..."
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

# Step 4: Fund MockSwapper with liquidity
echo "Funding MockSwapper with liquidity..."
flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

# Step 5: Create Tide position
echo "Creating Tide position with $INITIAL_DEPOSIT FLOW..."
flow transactions send transactions/flow-vaults/create_tide.cdc \
  --arg String:"tracer" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:$INITIAL_DEPOSIT \
  --signer test-account

# Step 6: Get the Tide ID
echo "Getting Tide ID..."
TIDE_ID=$(flow scripts execute scripts/flow-vaults/get_tide_ids.cdc \
  --arg Address:$YOUR_ADDRESS | grep -o '[0-9]\+' | head -1)
echo "Tide ID: $TIDE_ID"

# Step 7: Record baseline metrics
echo "=== RECORDING BASELINE METRICS ==="
echo "Initial FLOW Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

echo "Initial YieldToken Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

echo "Initial Tide Balance:"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "Initial AutoBalancer Balance:"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Step 8: Execute the test - Increase YieldToken price by 15%
echo "=== EXECUTING TEST: YIELD TOKEN PRICE INCREASE ==="
echo "Setting YieldToken price from $2.00 to $2.30 (+15%)"
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.30 \
  --signer test-account

echo "Confirming new YieldToken price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

# Step 9: Trigger rebalancing
echo "Triggering gain capture..."
flow transactions send transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account

# Step 10: Verify results
echo "=== VERIFYING RESULTS ==="
echo "Current YieldToken Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

echo "New AutoBalancer Balance:"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

echo "New Tide Balance (should be HIGHER from captured gains):"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "SCENARIO 3 COMPLETE!"
echo "Expected Results:"
echo "- AutoBalancer should trigger rebalanceSink (excess YieldTokens sold)"
echo "- Gains captured and transferred to position as collateral"
echo "- AutoBalancer rebalanced to target ratio"
```

**What You Should See:**

- **AutoBalancer triggers rebalanceSink** (YieldToken value exceeds threshold)
- **YieldToken balance decreases** (excess tokens sold at higher price)
- **Position strengthened** with gains transferred to collateral

---

## SCENARIO 4: YieldToken Depreciates (YieldToken Price Decreases)

**What happens:** YieldToken price decreases → AutoBalancer portfolio under-valued → NO automatic rebalancing (rebalanceSource = nil)

**Expected Outcome:** AutoBalancer cannot self-correct, manual intervention or position-level rebalancing may be needed

### Complete Self-Contained Test:

```bash
#!/bin/bash
echo "=== SCENARIO 4: YIELD TOKEN PRICE DECREASE ==="
echo "Setting up independent test environment..."

# Variables for this scenario
export YOUR_ADDRESS="0xf8d6e0586b0a20c7"  # Default test account
export INITIAL_DEPOSIT=100.0

# Step 1: Setup account for FlowVaults platform
echo "Setting up FlowVaults account..."
flow transactions send transactions/flow-vaults/setup.cdc \
  --signer test-account

# Step 2: Setup token vaults
echo "Setting up token vaults..."
flow transactions send transactions/moet/setup_vault.cdc \
  --signer test-account

flow transactions send transactions/yield-token/setup_vault.cdc \
  --signer test-account

# Step 3: Initialize token prices
echo "Setting initial token prices..."
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:2.0 \
  --signer test-account

flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:1.0 \
  --signer test-account

# Step 4: Fund MockSwapper with liquidity
echo "Funding MockSwapper with liquidity..."
flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.MOET.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

flow transactions send transactions/mocks/swapper/set_liquidity_connector.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:10000.0 \
  --signer test-account

# Step 5: Create Tide position
echo "Creating Tide position with $INITIAL_DEPOSIT FLOW..."
flow transactions send transactions/flow-vaults/create_tide.cdc \
  --arg String:"tracer" \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault" \
  --arg UFix64:$INITIAL_DEPOSIT \
  --signer test-account

# Step 6: Get the Tide ID
echo "Getting Tide ID..."
TIDE_ID=$(flow scripts execute scripts/flow-vaults/get_tide_ids.cdc \
  --arg Address:$YOUR_ADDRESS | grep -o '[0-9]\+' | head -1)
echo "Tide ID: $TIDE_ID"

# Step 7: Record baseline metrics
echo "=== RECORDING BASELINE METRICS ==="
echo "Initial FLOW Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.FlowToken.Vault"

echo "Initial YieldToken Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

echo "Initial Tide Balance:"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "Initial AutoBalancer Balance:"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

# Step 8: Execute the test - Decrease YieldToken price by 15%
echo "=== EXECUTING TEST: YIELD TOKEN PRICE DECREASE ==="
echo "Setting YieldToken price from $2.00 to $1.70 (-15%)"
flow transactions send transactions/mocks/oracle/set_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault" \
  --arg UFix64:1.70 \
  --signer test-account

echo "Confirming new YieldToken price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

# Step 9: Trigger rebalancing
echo "Triggering portfolio restoration..."
flow transactions send transactions/flow-vaults/admin/rebalance_auto_balancer_by_id.cdc \
  --arg UInt64:$TIDE_ID \
  --arg Bool:true \
  --signer test-account

# Step 10: Verify results
echo "=== VERIFYING RESULTS ==="
echo "Current YieldToken Price:"
flow scripts execute scripts/mocks/oracle/get_price.cdc \
  --arg String:"A.0ae53cb6e3f42a79.YieldToken.Vault"

echo "New AutoBalancer Balance (should be HIGHER in token count):"
flow scripts execute scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc \
  --arg UInt64:$TIDE_ID

echo "New Tide Balance:"
flow scripts execute scripts/flow-vaults/get_tide_balance.cdc \
  --arg Address:$YOUR_ADDRESS --arg UInt64:$TIDE_ID

echo "SCENARIO 4 COMPLETE!"
echo "Expected Results:"
echo "- AutoBalancer CANNOT rebalance automatically (no rebalanceSource)"
echo "- Portfolio remains under-valued"
echo "- Manual intervention or position-level rebalancing may be needed"
```

**What You Should See:**

- **AutoBalancer CANNOT rebalance** (no rebalanceSource configured)
- **YieldToken balance unchanged** (no automatic top-up mechanism)
- **Portfolio remains under-valued** (manual intervention may be needed)

---

## Notes

1. **Each scenario is completely independent** - run any scenario without running others first
2. **Only prerequisite is deployed contracts** - each scenario handles its own setup
3. **The `force: true` parameter** bypasses threshold checks for testing
4. **Position ID ≠ Tide ID** - they are different identifiers in the system
5. **Compare baseline vs final values** each scenario records and displays
6. **Each scenario demonstrates different market conditions** the protocol handles automatically
7. **Scripts are copy-paste ready** - save any scenario as a .sh file and execute independently

### Key Metrics to Monitor

#### AutoBalancer Health

```bash
# Current YieldToken holdings in AutoBalancer
scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc

# Compare against expected value based on deposits
# Ratio should stay between 0.95 - 1.05 for healthy positions
```

#### Position Metrics

```bash
# Overall position health (collateralization ratio)
scripts/flow-alp/position_health.cdc

# Available balance for withdrawal from position
scripts/flow-alp/get_available_balance.cdc
```

#### User Balance

```bash
# Total FLOW available for withdrawal from Tide
scripts/flow-vaults/get_tide_balance.cdc

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
4. **"Position not found"** - Verify FlowALP position ID (different from Tide ID)

#### Debugging Commands:

```bash
# Check if oracle has price set
flow scripts execute scripts/mocks/oracle/get_price.cdc --arg String:"TOKEN_TYPE"

# Check your Tide IDs
flow scripts execute scripts/flow-vaults/get_tide_ids.cdc --arg Address:0xYourAddress

# Check supported strategies
flow scripts execute scripts/flow-vaults/get_supported_strategies.cdc
```

This testing framework allows you to validate that the rebalancing system correctly responds to market conditions while maintaining position safety and optimizing yield generation.

## Key Features

### 1. Composable Strategies

- Strategies are built by composing [DeFi Actions](https://developers.flow.com/blockchain-development-tutorials/forte/flow-actions)
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

- Uses Cadence's [resource model](https://cadence-lang.org/docs/language/resources) for secure asset management
- Tides are resources owned by users
- Automatic cleanup when positions are closed

## Important Notes

**This is a mock implementation for development and testing purposes only. It is not intended for production use.**

The contracts include extensive mock components (MockOracle, MockSwapper, etc.) that simulate real DeFi infrastructure. In a production environment, these would be replaced with actual oracle services and DEX integrations.

## Getting Started

1. **Setup Account**: Run the setup transaction to initialize your TideManager
2. **Create Strategy**: Use create_tide to open a yield position
3. **Manage Position**: Deposit/withdraw funds as needed
4. **Monitor Performance**: Use scripts to track your positions
5. **Close Position**: Use close_tide to exit and reclaim all funds

The platform provides a foundation for sophisticated yield farming strategies while maintaining the security and composability principles of the Cadence programming language.
