import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowCreditMarket"

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

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means it's a deposit (collateral)
            if balance.direction == FlowCreditMarket.BalanceDirection.Credit {
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
            if balance.direction == FlowCreditMarket.BalanceDirection.Debit {
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

access(all)
fun test_RebalanceTideScenario3A() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0
	let flowPriceDecrease = 0.8
	let yieldPriceIncrease = 1.2

	let expectedYieldTokenValues = [615.38461538, 492.30769231, 460.74950690]
	let expectedFlowCollateralValues = [1000.00000000, 800.00000000, 898.46153846]
	let expectedDebtValues = [615.38461538, 492.30769231, 552.89940828]

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance before \(flowBalanceBefore)")
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

	setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)

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

	rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
	
	// Debug: Log position details
	let positionDetailsAfterRebalance = getPositionDetails(pid: pid, beFailed: false)
	log("[DEBUG] Position details after rebalance:")
	log("  Health: \(positionDetailsAfterRebalance.health)")
	log("  Default token available: \(positionDetailsAfterRebalance.defaultTokenAvailableBalance)")

	let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalance(id: tideIDs![0])!
	let flowCollateralAfterFlowDecrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterFlowDecrease = flowCollateralAfterFlowDecrease * flowPriceDecrease
	let debtAfterFlowDecrease = getMOETDebtFromPosition(pid: pid)
	
	log("\n=== PRECISION COMPARISON (After Flow Price Decrease) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
	log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceDecrease)")
	let diff1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceDecrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceDecrease
	let sign1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? "+" : "-"
	log("Difference:            \(sign1)\(diff1)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[1])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueAfterFlowDecrease)")
	log("Actual Flow Collateral Amount:  \(flowCollateralAfterFlowDecrease) Flow tokens")
	let flowDiff1 = flowCollateralValueAfterFlowDecrease > expectedFlowCollateralValues[1] ? flowCollateralValueAfterFlowDecrease - expectedFlowCollateralValues[1] : expectedFlowCollateralValues[1] - flowCollateralValueAfterFlowDecrease
	let flowSign1 = flowCollateralValueAfterFlowDecrease > expectedFlowCollateralValues[1] ? "+" : "-"
	log("Difference:                     \(flowSign1)\(flowDiff1)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[1])")
	log("Actual MOET Debt:   \(debtAfterFlowDecrease)")
	let debtDiff1 = debtAfterFlowDecrease > expectedDebtValues[1] ? debtAfterFlowDecrease - expectedDebtValues[1] : expectedDebtValues[1] - debtAfterFlowDecrease
	let debtSign1 = debtAfterFlowDecrease > expectedDebtValues[1] ? "+" : "-"
	log("Difference:         \(debtSign1)\(debtDiff1)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterFlowPriceDecrease, b:expectedYieldTokenValues[1], tolerance:0.01),
		message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueAfterFlowDecrease, b:expectedFlowCollateralValues[1], tolerance:0.01),
		message: "Expected flow collateral value after flow price decrease to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowDecrease)"
	)
	Test.assert(
		equalAmounts(a:debtAfterFlowDecrease, b:expectedDebtValues[1], tolerance:0.01),
		message: "Expected MOET debt after flow price decrease to be \(expectedDebtValues[1]) but got \(debtAfterFlowDecrease)"
	)

	setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

	rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: true, beFailed: false)
	//rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

	let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: tideIDs![0])!
	let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceDecrease  // Flow price remains at 0.8
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

	// Check getTideBalance vs actual available balance before closing
	let tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])!
	
	// Get the actual available balance from the position
	let positionDetails = getPositionDetails(pid: 1, beFailed: false)
	var positionFlowBalance = 0.0
	for balance in positionDetails.balances {
		if balance.vaultType == Type<@FlowToken.Vault>() && balance.direction == FlowCreditMarket.BalanceDirection.Credit {
			positionFlowBalance = balance.balance
			break
		}
	}
	
	log("\n=== DIAGNOSTIC: Tide Balance vs Position Available ===")
	log("getTideBalance() reports: \(tideBalance)")
	log("Position Flow balance: \(positionFlowBalance)")
	log("Difference: \(positionFlowBalance - tideBalance)")
	log("========================================\n")

	// Skip closeTide for now due to getTideBalance precision issues
	    closeTide(signer: user, id: tideIDs![0], beFailed: false)

	log("\n=== TEST COMPLETE - All precision checks passed ===")
}


