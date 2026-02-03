// this height guarantees enough liquidity for the test
#test_fork(network: "mainnet", height: 140164761)

import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV1_1"
import "FlowCreditMarket"
import "FlowYieldVaults"
import "ERC4626PriceOracles"

// check (and update) flow.json for correct addresses
// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let yieldTokenAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let evmAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means it's a deposit (collateral)
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

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

access(all)
fun setup() {
	// BandOracle is only used for FLOW price for FCM collateral
    let symbolPrices: {String: UFix64}   = {
        "FLOW": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	// service account does not have enough flow to "mint"
	// var mintFlowResult = mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)

	mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    // service account does not have enough flow to "mint"
	// mintFlowResult = mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)

	snapshot = getCurrentBlockHeight()
}

// PYUSD address (underlying asset of FUSDEV)
access(all) let PyUSD0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"

access(all)
fun changeYieldTokenPrice(price: UFix64) {
    // TODO: change yield token price
    // attempted: deployed mock evm contract with ability to impersonate any account
    // depositing into vault did not work as expected, might need ability to modify storage

}

access(all)
fun test_RebalanceYieldVaultScenario2() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0

	let user = Test.createAccount()

	let yieldPriceIncreases = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0]
	let expectedFlowBalance = [
	1061.53846154,
	1120.92522862,
	1178.40857368,
	1289.97388243,
	1554.58390959,
	2032.91742023
	]

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

    // Capture the actual position ID from the FlowCreditMarket.Opened event
	var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowCreditMarket.Opened>())) as! FlowCreditMarket.Opened).pid
	log("[TEST] Captured Position ID from event: \(pid)")

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)

	var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("[TEST] Initial yield vault balance: \(yieldVaultBalance ?? 0.0)")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

	for index, yieldTokenPrice in yieldPriceIncreases {
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

		// set yield token price 
        changeYieldTokenPrice(price: yieldTokenPrice)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: false, beFailed: false)

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

        // let percentToleranceCheck = equalAmounts(a: yieldVaultPercentDiff, b: 0.0, tolerance: forkedPercentTolerance)
        // Test.assert(percentToleranceCheck, message: "Percent difference \(yieldVaultPercentDiff)% is not within tolerance \(forkedPercentTolerance)%")
        // log("Percent difference \(yieldVaultPercentDiff)% is within tolerance \(forkedPercentTolerance)%")
	}

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")

	Test.assert(
		(flowBalanceAfter-flowBalanceBefore) > 0.1,
		message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	)
}

