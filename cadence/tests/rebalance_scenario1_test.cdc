import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	deployContracts()
	

	// set mocked token prices
	setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	setupMoetVault(protocolAccount, beFailed: false)
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

	// setup FlowCreditMarket with a Pool & add FLOW as supported token
	createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
	addSupportedTokenSimpleInterestCurve(
		signer: protocolAccount,
		tokenTypeIdentifier: flowTokenIdentifier,
		collateralFactor: 0.8,
		borrowFactor: 1.0,
		depositRate: 1_000_000.0,
		depositCapacityCap: 1_000_000.0
	)

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves
	let openRes = executeTransaction(
		"../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: flowVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
		beFailed: false
	)

	// Fund FlowVaults account for scheduling fees (atomic initial scheduling)
	mintFlow(to: flowVaultsAccount, amount: 100.0)

	snapshot = getCurrentBlockHeight()
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_RebalanceTideScenario1() {
	// Test.reset(to: snapshot)

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
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

	createTide(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var tideIDs = getTideIDs(address: user.address)
	var pid  = 1 as UInt64
	log("[TEST] Tide ID: \(tideIDs![0])")
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(1, tideIDs!.length)

	var tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("[TEST] Initial tide balance: \(tideBalance ?? 0.0)")

	rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

	testSnapshot = getCurrentBlockHeight()

	for flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before flow price \(flowPrice) \(tideBalance ?? 0.0)")

		setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before flow price \(flowPrice) rebalance: \(tideBalance ?? 0.0)")

		// Get yield token balance before rebalance
		let yieldTokensBefore = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
		let currentValueBefore = getAutoBalancerCurrentValue(id: tideIDs![0]) ?? 0.0
		
		rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: protocolAccount, pid: pid, force: false, beFailed: false)

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance after flow before \(flowPrice): \(tideBalance ?? 0.0)")
		
		// Get yield token balance after rebalance
		let yieldTokensAfter = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
		let currentValueAfter = getAutoBalancerCurrentValue(id: tideIDs![0]) ?? 0.0
		
		// Get expected yield tokens from Google sheet calculations
		let expectedYieldTokens = expectedYieldTokenValues[flowPrice] ?? 0.0
		
		log("\n=== SCENARIO 1 DETAILS for Flow Price \(flowPrice) ===")
		log("Tide Balance:          \(tideBalance ?? 0.0)")
		log("Yield Tokens Before:   \(yieldTokensBefore)")
		log("Yield Tokens After:    \(yieldTokensAfter)")
		log("Expected Yield Tokens: \(expectedYieldTokens)")
		let precisionDiff = yieldTokensAfter > expectedYieldTokens ? yieldTokensAfter - expectedYieldTokens : expectedYieldTokens - yieldTokensAfter
		let precisionSign = yieldTokensAfter > expectedYieldTokens ? "+" : "-"
		log("Precision Difference:  \(precisionSign)\(precisionDiff)")
		let percentDiff = expectedYieldTokens > 0.0 ? (precisionDiff / expectedYieldTokens) * 100.0 : 0.0
		log("Percent Difference:    \(precisionSign)\(percentDiff)%")
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

	closeTide(signer: user, id: tideIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")
}
