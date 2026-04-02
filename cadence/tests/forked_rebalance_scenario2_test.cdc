// Simulation spreadsheet: https://docs.google.com/spreadsheets/d/11DCzwZjz5K-78aKEWxt9NI-ut5LtkSyOT0TnRPUG7qY/edit?pli=1&gid=539924856#gid=539924856

#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV2"
import "FlowALPv0"
import "FlowYieldVaults"


// ============================================================================
// CADENCE ACCOUNTS
// ============================================================================

access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowALPAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV2.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

// ============================================================================
// PROTOCOL ADDRESSES
// ============================================================================

// Uniswap V3 Factory on Flow EVM mainnet
access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// ============================================================================
// VAULT & TOKEN ADDRESSES
// ============================================================================

// FUSDEV - Morpho VaultV2 (ERC4626)
// Underlying asset: PYUSD0
access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"

// PYUSD0 - Stablecoin (FUSDEV's underlying asset)
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"

// MOET - Flow ALP USD
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"

// WFLOW - Wrapped Flow
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

// Token balanceOf mapping slots (for EVM.store to manipulate balances)
access(all) let moetBalanceSlot = 0 as UInt256
access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wflowBalanceSlot = 3 as UInt256

// Morpho vault storage slots
access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

access(all)
fun setup() {
    // Deploy all contracts for mainnet fork
    deployContractsForFork()

    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 3000, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = {
        "FLOW": 1.0,
        "USD": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	// service account does not have enough flow to "mint"
	// var mintFlowResult = mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)

	mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

    // Grant FlowALPv1 Pool capability to FlowYieldVaults account
    let protocolBetaRes = grantProtocolBeta(flowALPAccount, flowYieldVaultsAccount)
    Test.expect(protocolBetaRes, Test.beSucceeded())

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    // service account does not have enough flow to "mint"
	// mintFlowResult = mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

/// Logs full position details (all balances with direction, health, etc.)
access(all)
fun logPositionDetails(label: String, pid: UInt64) {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    log("\n--- Position Details (\(label)) pid=\(pid) ---")
    log("  health: \(positionDetails.health)")
    log("  defaultTokenAvailableBalance: \(positionDetails.defaultTokenAvailableBalance)")
    for balance in positionDetails.balances {
        let direction = balance.direction.rawValue == 0 ? "CREDIT(collateral)" : "DEBIT(debt)"
        log("  [\(direction)] \(balance.vaultType.identifier): \(balance.balance)")
    }
    log("--- End Position Details ---")
}

access(all)
fun test_RebalanceYieldVaultScenario2() {
	let fundingAmount = 1000.0

	let user = Test.createAccount()

	// ===================================================================================
	// SCENARIO 2: YIELD price changes (up then down), testing full rebalancing cycle
	// ===================================================================================
	//
	// INITIAL STATE (after createYieldVault with 1000 FLOW):
	//   Collateral (C) = 1000 FLOW
	//   Collateral Factor (CF) = 0.8
	//   Target Health (H_target) = 1.3
	//   Debt (D) = C × CF / H_target = 1000 × 0.8 / 1.3 = 615.38
	//   YIELD Units (U) = D / Price = 615.38 / 1.0 = 615.38
	//   Baseline (B) = D = 615.38 (value at time of rebalancing)
	//   Health = C × CF / D = 1000 × 0.8 / 615.38 = 1.3
	//
	// THRESHOLDS:
	//   AutoBalancer: lowerThreshold=0.95, upperThreshold=1.05 (±5% of Baseline)
	//   Position: minHealth=1.1, targetHealth=1.3, maxHealth=1.5
	//
	// ===================================================================================
	// PHASE 1: YIELD PRICE INCREASES (1.0 → 3.0)
	// ===================================================================================
	// When Value/Baseline > 1.05, AutoBalancer sells surplus, then Position re-levers.
	//
	// STEP-BY-STEP CALCULATION (Price 1.0 → 1.1):
	//   1. YIELD Value = U × P = 615.38 × 1.1 = 676.92
	//   2. Value/Baseline = 676.92 / 615.38 = 1.10 > 1.05 → triggers sell
	//   3. Surplus = Value - Baseline = 676.92 - 615.38 = 61.54
	//   4. Units sold = Surplus / P = 61.54 / 1.1 = 55.94
	//   5. Remaining Units = 615.38 - 55.94 = 559.44
	//   6. Collateral += Surplus → C = 1000 + 61.54 = 1061.54 ✓
	//   7. AutoBalancer resets Baseline = 615.38 (remaining value)
	//   8. Position health = 1061.54 × 0.8 / 615.38 = 1.38 > 1.3 → re-lever
	//   9. New Debt = C × CF / H_target = 1061.54 × 0.8 / 1.3 = 653.26
	//  10. Additional Debt = 653.26 - 615.38 = 37.88
	//  11. Buy YIELD = 37.88 / 1.1 = 34.44 units
	//  12. Final: C=1061.54, D=653.26, U=593.88, B=653.26
	//
	// GENERAL FORMULA (for price increase with re-levering):
	//   Let r = new_price / old_price (price ratio)
	//   Surplus = B_old × (r - 1)
	//   C_new = C_old + Surplus = C_old + B_old × (r - 1)
	//   D_new = C_new × CF / H_target
	//   U_new = D_new / new_price
	//   B_new = D_new
	//
	// ===================================================================================
	// PHASE 2: YIELD PRICE DECREASES (3.0 → 0.5)
	// ===================================================================================
	// When Value/Baseline < 0.95, AutoBalancer needs to restore balance by pulling
	// from Position collateral. Position may de-lever if health drops below 1.1.
	//
	// STEP-BY-STEP CALCULATION (Price 3.0 → 2.5):
	//   State at P=3.0: C=2032.92, D=1251.03, U=417.01, B=1251.03
	//   1. YIELD Value = U × P = 417.01 × 2.5 = 1042.53
	//   2. Value/Baseline = 1042.53 / 1251.03 = 0.83 < 0.95 → triggers rebalance
	//   3. Deficit = Baseline - Value = 1251.03 - 1042.53 = 208.50
	//   4. AutoBalancer pulls 208.50 from Position collateral
	//   5. C_new = 2032.92 - 208.50 = 1824.42
	//   6. AutoBalancer buys YIELD: 208.50 / 2.5 = 83.40 units
	//   7. New Units = 417.01 + 83.40 = 500.41
	//   8. Position health = 1824.42 × 0.8 / 1251.03 = 1.17 (in [1.1, 1.5], no de-lever)
	//   9. Position re-targets: D_new = 1824.42 × 0.8 / 1.3 = 1122.72
	//  10. Repay debt: 1251.03 - 1122.72 = 128.31 (sell YIELD)
	//  11. Sell YIELD: 128.31 / 2.5 = 51.32 units
	//  12. Final: C=1746.22 ✓ (after accounting for round-trip swap costs)
	//
	// KEY INSIGHT - ROUND-TRIP INEFFICIENCY:
	//   At P=1.0 (back to original price): C=886.14, not 1000!
	//   Loss = (1000 - 886.14) / 1000 = 11.4%
	//   This loss comes from AutoBalancer selling ALL surplus (to B),
	//   then Position borrowing to re-lever (buying back YIELD).
	//   Each rebalance cycle has swap friction that accumulates.
	//
	// ===================================================================================
	// EXPECTED VALUES TABLE (all values cumulative from previous state)
	// ===================================================================================
	// Formulas for PRICE INCREASE (re-levering):
	//   C_new = C_old + B_old × (P_new/P_old - 1)
	//   D_new = C_new × CF / H_target = C_new × 0.8 / 1.3
	//   U_new = D_new / P_new
	//   B_new = D_new
	//
	// Formulas for PRICE DECREASE (de-levering when health < 1.1):
	//   Deficit = B_old - (U_old × P_new)
	//   C_temp = C_old - Deficit (AutoBalancer pulls from collateral)
	//   If health < 1.1: de-lever to H_target=1.3
	//   D_new = C_temp × CF / H_target
	//   U_new = D_new / P_new
	//   B_new = D_new
	// ===================================================================================
	//
	// Initial: C=1000.00, D=615.38, U=615.38, B=615.38, H=1.30
	//
	// Price | Dir  | Collateral |   Debt   | YIELD Units | Baseline | Health | Notes
	// ------|------|------------|----------|-------------|----------|--------|---------------------------
	// 1.10  | UP   |    1061.54 |   653.26 |      593.87 |   653.26 |   1.30 | Surplus=61.54
	// 1.20  | UP   |    1120.93 |   689.80 |      574.83 |   689.80 |   1.30 |
	// 1.30  | UP   |    1178.41 |   725.18 |      557.83 |   725.18 |   1.30 |
	// 1.50  | UP   |    1289.97 |   793.83 |      529.22 |   793.83 |   1.30 |
	// 2.00  | UP   |    1554.58 |   956.67 |      478.34 |   956.67 |   1.30 |
	// 3.00  | UP   |    2032.92 |  1251.03 |      417.01 |  1251.03 |   1.30 | Peak
	// ------|------|------------|----------|-------------|----------|--------|---------------------------
	// 2.50  | DOWN |    1746.22 |  1074.60 |      429.84 |  1074.60 |   1.30 | Deficit triggers rebalance
	// 2.00  | DOWN |    1459.53 |   897.40 |      448.70 |   897.40 |   1.30 |
	// 1.50  | DOWN |    1172.84 |   721.44 |      480.96 |   721.44 |   1.30 |
	// 1.00  | DOWN |     886.14 |   545.32 |      545.32 |   545.32 |   1.30 | ~11% loss at original P!
	// 0.80  | DOWN |     771.47 |   474.74 |      593.43 |   474.74 |   1.30 |
	// 0.50  | DOWN |     599.45 |   368.89 |      737.78 |   368.89 |   1.30 | 40% loss from original
	// ===================================================================================
	//
	// KEY OBSERVATIONS:
	// 1. During UP phase: D, B increase (more leverage); U decreases (fewer units at higher price)
	// 2. During DOWN phase: D, B decrease (de-leverage); U increases (more units at lower price)
	// 3. At P=1.00 (original): C=886.14 vs initial 1000 → 11.4% value lost to round-trips
	// 4. The loss comes from: sell high → buy back at same price costs swap fees each cycle
	// ===================================================================================
	let yieldPriceChanges = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0, 2.5, 2.0, 1.5, 1.0, 0.8, 0.5]
	let expectedFlowBalance = [
		1061.53846154,   // 1.10 UP
		1120.92522862,   // 1.20 UP
		1178.40857368,   // 1.30 UP
		1289.97388243,   // 1.50 UP
		1554.58390959,   // 2.00 UP
		2032.91742023,   // 3.00 UP (peak)
		// Price decreases from peak (cumulative)
		1746.22392914,   // 2.50 DOWN
		1459.53044824,   // 2.00 DOWN
		1172.83696734,   // 1.50 DOWN
		886.14348644,    // 1.00 DOWN (back to original price, but ~11% loss from round-trips)
		771.46609409,    // 0.80 DOWN
		599.45000554     // 0.50 DOWN (below original value, demonstrates losses accumulate)
	]

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1 price
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: 1.0,
        signer: user
    )

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

    // Capture the actual position ID from the FlowCreditMarket.Opened event
	var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid
	log("[TEST] Captured Position ID from event: \(pid)")

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)

	var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("[TEST] Initial yield vault balance: \(yieldVaultBalance ?? 0.0)")

	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	for index, yieldTokenPrice in yieldPriceChanges {
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: yieldTokenPrice,
            signer: user
        )

        // Update FUSDEV pools
        // Since FUSDEV is increasing in value we want to sell FUSDEV on the rebalance
        // FUSDEV -> PYUSD0 -> WFLOW
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: pyusd0Address,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldTokenPrice), fee: 100, reverse: true),
            tokenABalanceSlot: pyusd0BalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )

        // MOET -> FUSDEV
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: moetAddress,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldTokenPrice), fee: 100, reverse: false),
            tokenABalanceSlot: moetBalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

        // FUSDEV -> MOET for the yield balance check (we want to sell FUSDEV)
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: moetAddress,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldTokenPrice), fee: 100, reverse: true),
            tokenABalanceSlot: moetBalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// Perform comprehensive diagnostic precision trace
		performDiagnosticPrecisionTrace(
			yieldVaultID: yieldVaultIDs![0],
			pid: pid,
			yieldPrice: yieldTokenPrice,
			expectedValue: expectedFlowBalance[index],
			userAddress: user.address
		)

		// Get Flow collateral from position
		let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
		let flowCollateralValue = flowCollateralAmount * 1.0  // Flow price remains at 1.0

		// Detailed precision comparison
		let actualYieldVaultBalance = yieldVaultBalance ?? 0.0
		let expectedBalance = expectedFlowBalance[index]

		// Calculate differences
		let yieldVaultDiff = actualYieldVaultBalance > expectedBalance ? actualYieldVaultBalance - expectedBalance : expectedBalance - actualYieldVaultBalance
		let yieldVaultSign = actualYieldVaultBalance > expectedBalance ? "+" : "-"
		let yieldVaultPercentDiff = (yieldVaultDiff / expectedBalance) * 100.0

		let positionDiff = flowCollateralValue > expectedBalance ? flowCollateralValue - expectedBalance : expectedBalance - flowCollateralValue
		let positionSign = flowCollateralValue > expectedBalance ? "+" : "-"
		let positionPercentDiff = (positionDiff / expectedBalance) * 100.0

		let yieldVaultVsPositionDiff = actualYieldVaultBalance > flowCollateralValue ? actualYieldVaultBalance - flowCollateralValue : flowCollateralValue - actualYieldVaultBalance
		let yieldVaultVsPositionSign = actualYieldVaultBalance > flowCollateralValue ? "+" : "-"

		log("\n=== PRECISION COMPARISON for Yield Price \(yieldTokenPrice) ===")
		log("Expected Value:         \(expectedBalance)")
		log("Actual YieldVault Balance:    \(actualYieldVaultBalance)")
		log("Flow Position Value:    \(flowCollateralValue)")
		log("Flow Position Amount:   \(flowCollateralAmount) tokens")
		log("")
		log("YieldVault vs Expected:       \(yieldVaultSign)\(yieldVaultDiff) (\(yieldVaultSign)\(yieldVaultPercentDiff)%)")
		log("Position vs Expected:   \(positionSign)\(positionDiff) (\(positionSign)\(positionPercentDiff)%)")
		log("YieldVault vs Position:       \(yieldVaultVsPositionSign)\(yieldVaultVsPositionDiff)")
		log("===============================================\n")

        let percentToleranceCheck = equalAmounts(a: yieldVaultPercentDiff, b: 0.0, tolerance: 0.01)
        Test.assert(percentToleranceCheck, message: "Percent difference \(yieldVaultPercentDiff)% is not within tolerance \(0.01)%")
	}

	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	// let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	// log("[TEST] flow balance after \(flowBalanceAfter)")

	// Test.assert(
	// 	(flowBalanceAfter-flowBalanceBefore) > 0.1,
	// 	message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	// )
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

// Enhanced diagnostic precision tracking function with full call stack tracing
access(all) fun performDiagnosticPrecisionTrace(
    yieldVaultID: UInt64,
    pid: UInt64,
    yieldPrice: UFix64,
    expectedValue: UFix64,
    userAddress: Address
) {
    // Get position ground truth
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    var flowAmount: UFix64 = 0.0

    for balance in positionDetails.balances {
        if balance.vaultType.identifier == flowTokenIdentifier {
            if balance.direction.rawValue == 0 {  // Credit
                flowAmount = balance.balance
            }
        }
    }

    // Values at different layers
    let positionValue = flowAmount * 1.0  // Flow price = 1.0 in Scenario 2
    let yieldVaultValue = getYieldVaultBalance(address: userAddress, yieldVaultID: yieldVaultID) ?? 0.0

    // Calculate drifts with proper sign handling
    let yieldVaultDriftAbs = yieldVaultValue > expectedValue ? yieldVaultValue - expectedValue : expectedValue - yieldVaultValue
    let yieldVaultDriftSign = yieldVaultValue > expectedValue ? "+" : "-"
    let positionDriftAbs = positionValue > expectedValue ? positionValue - expectedValue : expectedValue - positionValue
    let positionDriftSign = positionValue > expectedValue ? "+" : "-"
    let yieldVaultVsPositionAbs = yieldVaultValue > positionValue ? yieldVaultValue - positionValue : positionValue - yieldVaultValue
    let yieldVaultVsPositionSign = yieldVaultValue > positionValue ? "+" : "-"

    // Enhanced logging with intermediate values
    log("\n+----------------------------------------------------------------+")
    log("|          PRECISION DRIFT DIAGNOSTIC - Yield Price \(yieldPrice)         |")
    log("+----------------------------------------------------------------+")
    log("| Layer          | Value          | Drift         | % Drift      |")
    log("|----------------|----------------|---------------|--------------|")
    log("| Position       | \(formatValue(positionValue)) | \(positionDriftSign)\(formatValue(positionDriftAbs)) | \(positionDriftSign)\(formatPercent(positionDriftAbs / expectedValue))% |")
    log("| YieldVault Balance   | \(formatValue(yieldVaultValue)) | \(yieldVaultDriftSign)\(formatValue(yieldVaultDriftAbs)) | \(yieldVaultDriftSign)\(formatPercent(yieldVaultDriftAbs / expectedValue))% |")
    log("| Expected       | \(formatValue(expectedValue)) | ------------- | ------------ |")
    log("|----------------|----------------|---------------|--------------|")
    log("| YieldVault vs Position: \(yieldVaultVsPositionSign)\(formatValue(yieldVaultVsPositionAbs))                                   |")
    log("+----------------------------------------------------------------+")

    // Log intermediate calculation values
    log("\n== INTERMEDIATE VALUES TRACE:")

    // Log position balance details
    log("- Position Balance Details:")
    log("  * Flow Amount (trueBalance): \(flowAmount)")

    // Skip the problematic UInt256 conversion entirely to avoid overflow
    log("- Expected Value Analysis:")
    log("  * Expected UFix64: \(expectedValue)")

    // Log precision loss summary without complex calculations
    log("- Precision Loss Summary:")
    log("  * Position vs Expected: \(positionDriftSign)\(formatValue(positionDriftAbs)) (\(positionDriftSign)\(formatPercent(positionDriftAbs / expectedValue))%)")
    log("  * YieldVault vs Expected: \(yieldVaultDriftSign)\(formatValue(yieldVaultDriftAbs)) (\(yieldVaultDriftSign)\(formatPercent(yieldVaultDriftAbs / expectedValue))%)")
    log("  * Additional YieldVault Loss: \(yieldVaultVsPositionSign)\(formatValue(yieldVaultVsPositionAbs))")

    // Warning if significant drift
    if yieldVaultDriftAbs > 0.00000100 {
        log("\n⚠️  WARNING: Significant precision drift detected!")
    }
}

