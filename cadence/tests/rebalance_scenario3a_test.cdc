import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalYieldStrategies"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@TidalYieldStrategies.TracerStrategy>().identifier
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
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	setupMoetVault(protocolAccount, beFailed: false)
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: Test.getAccount(0x0000000000000008), to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

	// setup TidalProtocol with a Pool & add FLOW as supported token
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
		"../transactions/mocks/position/create_wrapped_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: tidalYieldAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
		beFailed: false
	)


	snapshot = getCurrentBlockHeight()
}

access(all)
fun test_RebalanceTideScenario3A() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0
	let flowPriceDecrease = 0.8
	let yieldPriceIncrease = 1.2

	let expectedYieldTokenValues = [615.38461538, 492.30769231, 460.74950690]

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)

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

	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("[TEST] Tide balance before flow price decrease \(tideBalance ?? 0.0)")

	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("[TEST] Tide balance before flow price decrease rebalance: \(tideBalance ?? 0.0)")
	let yieldTokensBefore = getAutoBalancerBalance(id: tideIDs![0])!
	log("\n=== PRECISION COMPARISON (Before Flow Price Decrease) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
	log("Actual Yield Tokens:   \(yieldTokensBefore)")
	let diff0 = yieldTokensBefore > expectedYieldTokenValues[0] ? yieldTokensBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - yieldTokensBefore
	let sign0 = yieldTokensBefore > expectedYieldTokenValues[0] ? "+" : "-"
	log("Difference:            \(sign0)\(diff0)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensBefore, b:expectedYieldTokenValues[0], tolerance:0.01),
		message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
	)

	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("[TEST] Tide balance after flow price decrease rebalance: \(tideBalance ?? 0.0)")

	let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalance(id: tideIDs![0])!
	log("\n=== PRECISION COMPARISON (After Flow Price Decrease) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
	log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceDecrease)")
	let diff1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceDecrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceDecrease
	let sign1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? "+" : "-"
	log("Difference:            \(sign1)\(diff1)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterFlowPriceDecrease, b:expectedYieldTokenValues[1], tolerance:0.01),
		message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
	)

	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("[TEST] Tide balance before yield price increase rebalance: \(tideBalance ?? 0.0)")

	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	//rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: tideIDs![0])!
	log("\n=== PRECISION COMPARISON (After Yield Price Increase) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
	log("Actual Yield Tokens:   \(yieldTokensAfterYieldPriceIncrease)")
	let diff2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? yieldTokensAfterYieldPriceIncrease - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - yieldTokensAfterYieldPriceIncrease
	let sign2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? "+" : "-"
	log("Difference:            \(sign2)\(diff2)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterYieldPriceIncrease, b:expectedYieldTokenValues[2], tolerance:0.01),
		message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
	)

	log("[TEST] Tide balance after yield price increase rebalance: \(tideBalance ?? 0.0)")

	closeTide(signer: user, id: tideIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")
}


