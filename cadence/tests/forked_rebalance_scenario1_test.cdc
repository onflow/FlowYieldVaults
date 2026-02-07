// this height guarantees enough liquidity for the test
#test_fork(network: "mainnet", height: 140164761)

import Test
import BlockchainHelpers

import "test_helpers.cdc"

// FlowYieldVaults platform
import "FlowYieldVaults"
// other
import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV1_1"
import "FlowCreditMarket"


// check (and update) flow.json for correct addresses
// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let yieldTokenAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    // BandOracle is only used for FLOW price for FCM collateral
    let symbolPrices: {String: UFix64}   = { 
        "FLOW": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

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
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_ForkedRebalanceYieldVaultScenario1() {
	let fundingAmount = 1000.0

	let user = Test.createAccount()

	let flowPrices = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0]
	
	// Expected values from Google sheet calculations
	let expectedYieldTokenValues: {UFix64: UFix64} = {
		0.5: 307.69230769,
		0.8: 492.30769231,
		1.0: 615.38461538,
		1.2: 738.46153846,
		1.5: 923.07692308,
		2.0: 1230.76923077,
		3.0: 1846.15384615,
		5.0: 3076.92307692
	}

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    // service account does not have enough flow to "mint"
	// let mintFlowResult =The code snippet `mintFlow(to: user, amount: fundingAmount)` is a function call that mints a specified amount of a token (in this case, Flow tokens) to a specific user account.
    // mintFlow(to: user, amount: fundingAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
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

	testSnapshot = getCurrentBlockHeight()

	for flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) \(yieldVaultBalance ?? 0.0)")

		setBandOraclePrice(signer: bandOracleAccount, symbol: "FLOW", price: flowPrice)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// Get yield token balance before rebalance
		let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let currentValueBefore = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0
		
		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: false, beFailed: false)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after flow before \(flowPrice): \(yieldVaultBalance ?? 0.0)")
		
		// Get yield token balance after rebalance
		let yieldTokensAfter = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let currentValueAfter = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0
		
		// Get expected yield tokens from Google sheet calculations
		let expectedYieldTokens = expectedYieldTokenValues[flowPrice] ?? 0.0
		
		log("\n=== SCENARIO 1 DETAILS for Flow Price \(flowPrice) ===")
		log("YieldVault Balance:          \(yieldVaultBalance ?? 0.0)")
		log("Yield Tokens Before:   \(yieldTokensBefore)")
		log("Yield Tokens After:    \(yieldTokensAfter)")
		log("Expected Yield Tokens: \(expectedYieldTokens)")
		let precisionDiff = yieldTokensAfter > expectedYieldTokens ? yieldTokensAfter - expectedYieldTokens : expectedYieldTokens - yieldTokensAfter
		let precisionSign = yieldTokensAfter > expectedYieldTokens ? "+" : "-"
		log("Precision Difference:  \(precisionSign)\(precisionDiff)")
		let percentDiff = expectedYieldTokens > 0.0 ? (precisionDiff / expectedYieldTokens) * 100.0 : 0.0
		log("Percent Difference:    \(precisionSign)\(percentDiff)%")
        
        // check if percent difference is within tolerance
        let percentToleranceCheck = equalAmounts(a: percentDiff, b: 0.0, tolerance: forkedPercentTolerance)
        Test.assert(percentToleranceCheck, message: "Percent difference \(percentDiff)% is not within tolerance \(forkedPercentTolerance)%")
        log("Percent difference \(percentDiff)% is within tolerance \(forkedPercentTolerance)%")

		let yieldChange = yieldTokensAfter > yieldTokensBefore ? yieldTokensAfter - yieldTokensBefore : yieldTokensBefore - yieldTokensAfter
		let yieldSign = yieldTokensAfter > yieldTokensBefore ? "+" : "-"
		log("Yield Token Change:    \(yieldSign)\(yieldChange)")
		log("Current Value Before:  \(currentValueBefore)")
		log("Current Value After:   \(currentValueAfter)")
		let valueChange = currentValueAfter > currentValueBefore ? currentValueAfter - currentValueBefore : currentValueBefore - currentValueAfter
		let valueSign = currentValueAfter > currentValueBefore ? "+" : "-"
		log("Value Change:          \(valueSign)\(valueChange)")
		log("=============================================\n")
	}

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")
}
