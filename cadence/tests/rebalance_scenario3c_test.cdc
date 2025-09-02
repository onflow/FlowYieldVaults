import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalYieldStrategies"
import "TidalProtocol"

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

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means it's a deposit (collateral)
            if balance.direction == TidalProtocol.BalanceDirection.Credit {
                return balance.balance
            }
        }
    }
    return 0.0
}

// Helper function to get MOET debt from position
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            // Debit means it's borrowed (debt)
            if balance.direction == TidalProtocol.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}

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
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
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
		"../../lib/TidalProtocol/cadence/tests/transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
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
fun test_RebalanceTideScenario3C() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0
	let flowPriceIncrease = 2.0
	let yieldPriceIncrease = 2.0

	let expectedYieldTokenValues = [615.38461539, 1230.76923077, 994.08284024]
	let expectedFlowCollateralValues = [1000.0, 2000.0, 3230.76923077]
	let expectedDebtValues = [615.38461539, 1230.76923077, 1988.16568047]

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance before \(flowBalanceBefore)")
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

	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceIncrease)

	let yieldTokensBefore = getAutoBalancerBalance(id: tideIDs![0])!
	let debtBefore = getMOETDebtFromPosition(pid: pid)
	let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueBefore = flowCollateralBefore * 1.0  // Initial price is 1.0
	
	log("\n=== PRECISION COMPARISON (Initial State) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
	log("Actual Yield Tokens:   \(yieldTokensBefore)")
	let diff0 = yieldTokensBefore > expectedYieldTokenValues[0] ? yieldTokensBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - yieldTokensBefore
	let sign0 = yieldTokensBefore > expectedYieldTokenValues[0] ? "+" : "-"
	log("Difference:            \(sign0)\(diff0)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[0])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueBefore)")
	let flowDiff0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? flowCollateralValueBefore - expectedFlowCollateralValues[0] : expectedFlowCollateralValues[0] - flowCollateralValueBefore
	let flowSign0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? "+" : "-"
	log("Difference:                     \(flowSign0)\(flowDiff0)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[0])")
	log("Actual MOET Debt:   \(debtBefore)")
	let debtDiff0 = debtBefore > expectedDebtValues[0] ? debtBefore - expectedDebtValues[0] : expectedDebtValues[0] - debtBefore
	let debtSign0 = debtBefore > expectedDebtValues[0] ? "+" : "-"
	log("Difference:         \(debtSign0)\(debtDiff0)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensBefore, b:expectedYieldTokenValues[0], tolerance:0.01),
		message: "Expected yield tokens to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueBefore, b:expectedFlowCollateralValues[0], tolerance:0.01),
		message: "Expected flow collateral value to be \(expectedFlowCollateralValues[0]) but got \(flowCollateralValueBefore)"
	)
	Test.assert(
		equalAmounts(a:debtBefore, b:expectedDebtValues[0], tolerance:0.01),
		message: "Expected MOET debt to be \(expectedDebtValues[0]) but got \(debtBefore)"
	)

	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

	let yieldTokensAfterFlowPriceIncrease = getAutoBalancerBalance(id: tideIDs![0])!
	let flowCollateralAfterFlowIncrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterFlowIncrease = flowCollateralAfterFlowIncrease * flowPriceIncrease
	let debtAfterFlowIncrease = getMOETDebtFromPosition(pid: pid)
	
	log("\n=== PRECISION COMPARISON (After Flow Price Increase) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
	log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceIncrease)")
	let diff1 = yieldTokensAfterFlowPriceIncrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceIncrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceIncrease
	let sign1 = yieldTokensAfterFlowPriceIncrease > expectedYieldTokenValues[1] ? "+" : "-"
	log("Difference:            \(sign1)\(diff1)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[1])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueAfterFlowIncrease)")
	log("Actual Flow Collateral Amount:  \(flowCollateralAfterFlowIncrease) Flow tokens")
	let flowDiff1 = flowCollateralValueAfterFlowIncrease > expectedFlowCollateralValues[1] ? flowCollateralValueAfterFlowIncrease - expectedFlowCollateralValues[1] : expectedFlowCollateralValues[1] - flowCollateralValueAfterFlowIncrease
	let flowSign1 = flowCollateralValueAfterFlowIncrease > expectedFlowCollateralValues[1] ? "+" : "-"
	log("Difference:                     \(flowSign1)\(flowDiff1)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[1])")
	log("Actual MOET Debt:   \(debtAfterFlowIncrease)")
	let debtDiff1 = debtAfterFlowIncrease > expectedDebtValues[1] ? debtAfterFlowIncrease - expectedDebtValues[1] : expectedDebtValues[1] - debtAfterFlowIncrease
	let debtSign1 = debtAfterFlowIncrease > expectedDebtValues[1] ? "+" : "-"
	log("Difference:         \(debtSign1)\(debtDiff1)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterFlowPriceIncrease, b:expectedYieldTokenValues[1], tolerance:0.01),
		message: "Expected yield tokens after flow price increase to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceIncrease)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueAfterFlowIncrease, b:expectedFlowCollateralValues[1], tolerance:0.01),
		message: "Expected flow collateral value after flow price increase to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowIncrease)"
	)
	Test.assert(
		equalAmounts(a:debtAfterFlowIncrease, b:expectedDebtValues[1], tolerance:0.01),
		message: "Expected MOET debt after flow price increase to be \(expectedDebtValues[1]) but got \(debtAfterFlowIncrease)"
	)

	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	//rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

	let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: tideIDs![0])!
	let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceIncrease  // Flow price remains at 2.0
	let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
	
	log("\n=== PRECISION COMPARISON (After Yield Price Increase) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
	log("Actual Yield Tokens:   \(yieldTokensAfterYieldPriceIncrease)")
	let diff2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? yieldTokensAfterYieldPriceIncrease - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - yieldTokensAfterYieldPriceIncrease
	let sign2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? "+" : "-"
	log("Difference:            \(sign2)\(diff2)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[2])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueAfterYieldIncrease)")
	log("Actual Flow Collateral Amount:  \(flowCollateralAfterYieldIncrease) Flow tokens")
	let flowDiff2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? flowCollateralValueAfterYieldIncrease - expectedFlowCollateralValues[2] : expectedFlowCollateralValues[2] - flowCollateralValueAfterYieldIncrease
	let flowSign2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? "+" : "-"
	log("Difference:                     \(flowSign2)\(flowDiff2)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[2])")
	log("Actual MOET Debt:   \(debtAfterYieldIncrease)")
	let debtDiff2 = debtAfterYieldIncrease > expectedDebtValues[2] ? debtAfterYieldIncrease - expectedDebtValues[2] : expectedDebtValues[2] - debtAfterYieldIncrease
	let debtSign2 = debtAfterYieldIncrease > expectedDebtValues[2] ? "+" : "-"
	log("Difference:         \(debtSign2)\(debtDiff2)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterYieldPriceIncrease, b:expectedYieldTokenValues[2], tolerance:0.01),
		message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueAfterYieldIncrease, b:expectedFlowCollateralValues[2], tolerance:0.01),
		message: "Expected flow collateral value after yield price increase to be \(expectedFlowCollateralValues[2]) but got \(flowCollateralValueAfterYieldIncrease)"
	)
	Test.assert(
		equalAmounts(a:debtAfterYieldIncrease, b:expectedDebtValues[2], tolerance:0.01),
		message: "Expected MOET debt after yield price increase to be \(expectedDebtValues[2]) but got \(debtAfterYieldIncrease)"
	)
	


	        // Skip closeTide for now due to getTideBalance precision issues
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
        
        log("\n=== TEST COMPLETE ===")
}


