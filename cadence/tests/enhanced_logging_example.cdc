// Example test demonstrating enhanced logging capabilities
// This shows how we would log all important state information

/*
ENHANCED LOGGING CAPABILITIES:

1. Comprehensive Position State Logging:
   - Position ID and Health Ratio
   - All prices (FLOW, MOET, YieldToken)
   - Collateral balance and value
   - MOET debt amount and type (borrowed/deposited)
   - Effective collateral and utilization rate

2. Comprehensive Auto-Balancer State Logging:
   - Tide ID and AutoBalancer ID
   - All current prices
   - YieldToken holdings and values
   - Expected vs actual performance
   - Rebalancing threshold status

3. State Change Tracking:
   - Before/after snapshots
   - Detailed change calculations
   - Clear visualization of what changed

Example output would look like:

╔═══════════════════════════════════════════════════════════════════╗
║ POSITION STATE: Before Rebalance
╠═══════════════════════════════════════════════════════════════════╣
║ Position ID: 0
║ Health Ratio: 0.65000000
╠═══════════════════════════════════════════════════════════════════╣
║ PRICES:
║   FLOW: 0.50000000 MOET
║   MOET: 1.00000000 (pegged)
╠═══════════════════════════════════════════════════════════════════╣
║ BALANCES:
║   FLOW Collateral: 1000.00000000
║   → Value: 500.00000000 MOET
║   MOET Debt: 615.38461538 (BORROWED)
║   → Value: 615.38461538 MOET
╠═══════════════════════════════════════════════════════════════════╣
║ METRICS:
║   Effective Collateral: 400.00000000 MOET
║   Utilization Rate: 153.84615385%
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║ AUTO-BALANCER STATE: Before Rebalance
╠═══════════════════════════════════════════════════════════════════╣
║ Tide ID: 1
║ AutoBalancer ID: 1
╠═══════════════════════════════════════════════════════════════════╣
║ PRICES:
║   FLOW: 0.50000000 MOET
║   YieldToken: 1.20000000 MOET
║   MOET: 1.00000000 (pegged)
╠═══════════════════════════════════════════════════════════════════╣
║ HOLDINGS:
║   YieldToken Balance: 615.38461538
║   → Value in MOET: 738.46153846
║   → Value in USD: 738.46153846
╠═══════════════════════════════════════════════════════════════════╣
║ POSITION METRICS:
║   Initial FLOW Deposit: 1000.00000000
║   Initial Value: 500.00000000 MOET
║   Expected MOET Borrowed: ~307.69230769
║   Expected YieldTokens: ~256.41025641
╠═══════════════════════════════════════════════════════════════════╣
║ PERFORMANCE:
║   Current/Expected Value: 240.00000000%
║   Status: ABOVE threshold (>105%) - should rebalance DOWN
╚═══════════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────────┐
│ STATE CHANGES AFTER: Rebalancing
├─────────────────────────────────────────────────────────────────┤
│ Health: 0.65000000 → 0.86666666 (+0.21666666)
│ MOET Debt: 615.38461538 → 461.53846154 (-153.84615384)
│ YieldToken: 615.38461538 → 512.82051282 (-102.56410256)
└─────────────────────────────────────────────────────────────────┘

This enhanced logging provides much more intelligence about:
1. Exact collateral amounts and their values
2. Debt levels and how they change
3. YieldToken holdings and performance metrics
4. Price impacts on all components
5. Clear indication of whether rebalancing is needed
6. Tracking of MOET depeg scenarios

To implement in tests, update the logging calls:

// Instead of:
logPositionDetails(pid: 0, stage: "Before Rebalance")

// Use:
logComprehensivePositionState(
    pid: 0, 
    stage: "Before Rebalance", 
    flowPrice: 0.5, 
    moetPrice: 1.0
)

// And for auto-balancers:
logComprehensiveAutoBalancerState(
    id: autoBalancerID,
    tideID: tideID,
    stage: "Before Rebalance",
    flowPrice: 0.5,
    yieldPrice: 1.2,
    moetPrice: 1.0,
    initialDeposit: 1000.0
)

// Track state changes:
let beforeSnapshot = StateSnapshot(
    health: healthBefore,
    collateralAmount: collateralBefore,
    debtAmount: debtBefore,
    yieldBalance: yieldBalanceBefore,
    flowPrice: flowPrice,
    yieldPrice: yieldPrice,
    moetPrice: moetPrice
)

// After rebalancing...
logStateChanges(before: beforeSnapshot, after: afterSnapshot, operation: "Rebalancing")
*/ 