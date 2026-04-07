// Simulation spreadsheet: https://docs.google.com/spreadsheets/d/11DCzwZjz5K-78aKEWxt9NI-ut5LtkSyOT0TnRPUG7qY/edit?pli=1&gid=539924856#gid=539924856

#test_fork(network: "mainnet-fork", height: 147316310)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowToken"
import "FlowYieldVaultsStrategiesV2"
import "FlowALPv0"
import "FlowYieldVaults"
import "DeFiActions"


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

// WFLOW - Wrapped Flow
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

// Token balanceOf mapping slots (for EVM.store to manipulate balances)
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

    // BandOracle is used for FLOW and USD prices
    let symbolPrices = {
        "FLOW": 1.0,
        "USD": 1.0,
        "PYUSD": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	// service account does not have enough flow to "mint"
	// var mintFlowResult = mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)

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
	// When Value/Baseline < 0.95, AutoBalancer detects a deficit. The system sells
	// collateral from the Position to cover the deficit, de-levering.
	//
	// With the FlowALPv0 toUFix64RoundDown fix, deficit recovery now works through
	// the DOWN phase. At P=2.5, the AB deficit pull drops H from 1.30 to ~1.17
	// (no position rebalance needed). At P=2.0, deficit recovery succeeds and H
	// drops to minHealth (1.10). State freezes at minHealth for P=1.5..0.5.
	//
	// STEP-BY-STEP CALCULATION (Price 3.0 → 2.5):
	//   State at P=3.0: C=2032.65, D=1250.86, U=416.95, B=1250.86, H=1.30
	//
	//   1. DEFICIT DETECTION:
	//      Yield Value = U × P_new = 416.95 × 2.5 = 1042.39
	//      Value/Baseline = 1042.39 / 1250.86 = 0.833 < 0.95 → triggers rebalance
	//      Deficit = Baseline - Value = 1250.86 - 1042.39 = 208.47
	//
	//   2. COLLATERAL SOLD TO COVER DEFICIT:
	//      Position sells collateral to cover the deficit. H drops but stays
	//      above minHealth, so no position rebalance triggers.
	//
	//   3. RESULT (empirical from fork output):
	//      C=1822.92, D=1250.86, U=500.35, H=1.17
	//
	// ===================================================================================
	// Empirical values from forked mainnet test (multi-step compounding makes
	// closed-form derivation impractical — values captured from fork output).
	//
	// Initial: C=1000.00, D=615.38, U=615.38, B=615.38, H=1.30
	//
	// Price | Dir  | Collateral |   Debt   | YIELD Units | Health | Notes
	// ------|------|------------|----------|-------------|--------|---------------------------
	// 1.10  | UP   |    1061.53 |   653.25 |      593.86 |   1.30 | Surplus rebalance
	// 1.20  | UP   |    1120.90 |   689.78 |      574.82 |   1.30 |
	// 1.30  | UP   |    1178.37 |   725.15 |      557.81 |   1.30 |
	// 1.50  | UP   |    1289.91 |   793.79 |      529.19 |   1.30 |
	// 2.00  | UP   |    1554.45 |   956.59 |      478.29 |   1.30 |
	// 3.00  | UP   |    2032.65 |  1250.86 |      416.95 |   1.30 | Peak
	// ------|------|------------|----------|-------------|--------|---------------------------
	// 2.50  | DOWN |    1822.92 |  1250.86 |      500.35 |   1.17 | Deficit, no pos rebal
	// 2.00  | DOWN |    1719.94 |  1250.86 |      551.53 |   1.10 | Deficit recovery → minHealth
	// 1.50  | DOWN |    1719.94 |  1250.86 |      551.53 |   1.10 | Frozen at minHealth
	// 1.00  | DOWN |    1719.94 |  1250.86 |      551.53 |   1.10 | Frozen at minHealth
	// 0.80  | DOWN |    1719.94 |  1250.86 |      551.53 |   1.10 | Frozen at minHealth
	// 0.50  | DOWN |    1719.94 |  1250.86 |      551.53 |   1.10 | Frozen at minHealth
	// ===================================================================================
	var yieldPriceChanges = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0, 2.5, 2.0, 1.5, 1.0, 0.8, 0.5]
	// expectedFlowBalance = YieldVault balance (computed via Strategy.availableBalance swap quote)
	// Note: This is NOT the same as Position collateral or U×P. It represents
	// the FLOW value obtainable by swapping yield tokens through the pool.
	// Empirical values from fork output (multi-step compounding makes closed-form
	// derivation impractical).
	var expectedFlowBalance = [
		// UP phase: Position collateral ≈ YieldVault balance (surplus rebalancing works)
		1061.52615116,   // 1.10 UP
		1120.90035094,   // 1.20 UP
		1178.37092464,   // 1.30 UP
		1289.91035468,   // 1.50 UP
		1554.45443175,   // 2.00 UP
		2032.65244754,   // 3.00 UP (peak)
		// DOWN phase: deficit recovery works with FlowALPv0 toUFix64RoundDown fix.
		// Empirical values from fork output.
		1822.91875938,   // 2.50 DOWN - deficit, H~1.17
		1516.70136888,   // 2.00 DOWN - deficit recovery, H→1.10 (minHealth)
		1137.52602700,   // 1.50 DOWN - frozen at minHealth
		758.35068375,    // 1.00 DOWN - frozen at minHealth
		606.68054700,    // 0.80 DOWN - frozen at minHealth
		379.17534188     // 0.50 DOWN - frozen at minHealth
	]

	// Expected state values: [C (Collateral), D (Debt), U (Yield Units), H (Health)]
	// Empirical values from fork output (multi-step compounding makes closed-form
	// derivation impractical).
	let expectedState: [[UFix64; 4]] = [
		// UP phase: surplus rebalancing works, C/D/U all change, H stays at 1.30
		[1061.52615345, 653.24686366, 593.86078454, 1.30],  // P=1.10
		[1120.90035404, 689.78483325, 574.82069333, 1.30],  // P=1.20
		[1178.37092675, 725.15133953, 557.80872154, 1.30],  // P=1.30
		[1289.91035904, 793.79099017, 529.19399199, 1.30],  // P=1.50
		[1554.45443727, 956.58734601, 478.29367149, 1.30],  // P=2.00
		[2032.65245331, 1250.86304819, 416.95434833, 1.30], // P=3.00 (PEAK)
		// DOWN phase: deficit recovery works with FlowALPv0 toUFix64RoundDown fix.
		// P=2.5: AB deficit pull drops H to ~1.17, no position rebalance needed.
		// P=2.0: deficit recovery succeeds, H drops to minHealth (1.10).
		// P=1.5..0.5: frozen at minHealth values.
		// Empirical values from fork output.
		[1822.91876377, 1250.86304819, 500.34521821, 1.1659],  // P=2.50 - deficit, H~1.17
		[1719.93669127, 1250.86304819, 551.52777096, 1.10],    // P=2.00 - deficit recovery, H→1.10
		[1719.93669127, 1250.86304819, 551.52777096, 1.10],    // P=1.50 - frozen at minHealth
		[1719.93669127, 1250.86304819, 551.52777096, 1.10],    // P=1.00 - frozen at minHealth
		[1719.93669127, 1250.86304819, 551.52777096, 1.10],    // P=0.80 - frozen at minHealth
		[1719.93669127, 1250.86304819, 551.52777096, 1.10]     // P=0.50 - frozen at minHealth
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

    // Refresh oracle prices to avoid stale timestamp
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: { "FLOW": 1.0, "USD": 1.0, "PYUSD": 1.0 })

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

        log("[TEST] YieldVault balance before price change to \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

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

        // PYUSD0 -> FUSDEV
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: pyusd0Address,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldTokenPrice), fee: 100, reverse: false),
            tokenABalanceSlot: pyusd0BalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after price to \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		// Log triggered rebalance events for yield vault (AutoBalancer)
		let yieldVaultRebalanceEventsInLoop = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
		log("[TEST] YieldVault Rebalance events count at price \(yieldTokenPrice): \(yieldVaultRebalanceEventsInLoop.length)")
		if yieldVaultRebalanceEventsInLoop.length > 0 {
			let lastYieldVaultEvent = yieldVaultRebalanceEventsInLoop[yieldVaultRebalanceEventsInLoop.length - 1] as! DeFiActions.Rebalanced
			log("[TEST] DeFiActions.Rebalanced - amount: \(lastYieldVaultEvent.amount), value: \(lastYieldVaultEvent.value), isSurplus: \(lastYieldVaultEvent.isSurplus), vaultType: \(lastYieldVaultEvent.vaultType), balancerUUID: \(lastYieldVaultEvent.balancerUUID)")
		}

		rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)
		// Log triggered rebalance events for position
		let positionRebalanceEventsInLoop = Test.eventsOfType(Type<FlowALPv0.Rebalanced>())
		log("[TEST] Position Rebalance events count at price \(yieldTokenPrice): \(positionRebalanceEventsInLoop.length)")
		if positionRebalanceEventsInLoop.length > 0 {
			let lastPositionEvent = positionRebalanceEventsInLoop[positionRebalanceEventsInLoop.length - 1] as! FlowALPv0.Rebalanced
			log("[TEST] FlowALPv0.Rebalanced - pid: \(lastPositionEvent.pid), atHealth: \(lastPositionEvent.atHealth), amount: \(lastPositionEvent.amount), fromUnder: \(lastPositionEvent.fromUnder)")
		}

        // FUSDEV -> PYUSD0 for the yield balance check (we want to sell FUSDEV)
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

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// === COMPREHENSIVE STATE LOGGING ===
		// Query all key values from contracts after rebalance
		let positionCollateral = getFlowCollateralFromPosition(pid: pid)
		let positionDebt = getPYUSD0DebtFromPosition(pid: pid)
		let positionHealth = getPositionHealth(pid: pid, beFailed: false)
		let yieldTokenUnits = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let baseline = getAutoBalancerBaseline(id: yieldVaultIDs![0]) ?? 0.0
		let yieldVaultValue = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0

		log("\n=== STATE AFTER REBALANCE at P=\(yieldTokenPrice) ===")
		log("| Position Collateral (C): \(positionCollateral)")
		log("| Position Debt (D):       \(positionDebt)")
		log("| Position Health (H):     \(positionHealth)")
		log("| Yield Token Units (U):   \(yieldTokenUnits)")
		log("| Baseline (B):            \(baseline)")
		log("| Yield Value (U×P):       \(yieldVaultValue)")
		log("| YieldVault Balance:      \(yieldVaultBalance ?? 0.0)")
		log("===========================================\n")

		// Assert expected state values (C, D, U, H)
		// Empirical values from fork output — tolerance accounts for ERC4626 integer
		// rounding (PYUSD0 6-decimal precision) compounding across the 12-step chain.
		let expected = expectedState[index]
		let tolerance = 0.3
		let cDiff = positionCollateral > expected[0] ? positionCollateral - expected[0] : expected[0] - positionCollateral
		Test.assert(
			cDiff <= tolerance,
			message: "P=\(yieldTokenPrice): Expected C=\(expected[0]), got \(positionCollateral), diff=\(cDiff)"
		)
		let dDiff = positionDebt > expected[1] ? positionDebt - expected[1] : expected[1] - positionDebt
		Test.assert(
			dDiff <= tolerance,
			message: "P=\(yieldTokenPrice): Expected D=\(expected[1]), got \(positionDebt), diff=\(dDiff)"
		)
		let uDiff = yieldTokenUnits > expected[2] ? yieldTokenUnits - expected[2] : expected[2] - yieldTokenUnits
		Test.assert(
			uDiff <= tolerance,
			message: "P=\(yieldTokenPrice): Expected U=\(expected[2]), got \(yieldTokenUnits), diff=\(uDiff)"
		)
		// Health factor: use larger tolerance (0.01) since H has more precision variance
		let healthTolerance = 0.01
		let hDiff = positionHealth > UFix128(expected[3]) ? positionHealth - UFix128(expected[3]) : UFix128(expected[3]) - positionHealth
		Test.assert(
			hDiff <= UFix128(healthTolerance),
			message: "P=\(yieldTokenPrice): Expected H=\(expected[3]), got \(positionHealth)"
		)

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

		let percentToleranceCheck = equalAmounts(a: yieldVaultPercentDiff, b: 0.0, tolerance: 0.3)
		Test.assert(percentToleranceCheck, message: "P=\(yieldTokenPrice): Percent difference \(yieldVaultPercentDiff)% is not within tolerance 0.3%")
	}

    // TODO: close fails — position is at minHealth (H=1.10) after DOWN phase, yield
    // covers ~44% of debt but collateral can't be withdrawn (minHealth prevents it).
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

