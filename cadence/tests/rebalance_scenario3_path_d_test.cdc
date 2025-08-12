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

// Inline helper for generated tests
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            if balance.direction.rawValue == 1 {  // Debit = 1
                return balance.balance
            }
        }
    }
    return 0.0
}

// Inline helper for generated tests (align with legacy tests)
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means collateral deposit
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

// Debug helper to log per-step comparisons (machine-parsable)
access(all) fun logStep(_ label: String, _ i: Int, _ actualDebt: UFix64, _ expectedDebt: UFix64, _ actualY: UFix64, _ expectedY: UFix64, _ actualColl: UFix64, _ expectedColl: UFix64) {
    log("DRIFT|\(label)|\(i)|\(actualDebt)|\(expectedDebt)|\(actualY)|\(expectedY)|\(actualColl)|\(expectedColl)")
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
fun test_RebalanceTideScenario3_Path_D() {
	let fundingAmount = 1000.0
	let user = Test.createAccount()
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
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(1, tideIDs!.length)
	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	// Step 0: start
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.00000000)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
	var actualDebt = getMOETDebtFromPosition(pid: pid)
	var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
	var flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
	var actualCollateral = flowCollateralAmount * 1.00000000
	logStep("Scenario3_Path_D", 0, actualDebt, 615.38461539, actualYieldUnits, 615.38461539, actualCollateral, 1000.00000000)
	Test.assert(equalAmounts(a: actualDebt, b: 615.38461539, tolerance: 0.0000001), message: "Debt mismatch at step 0")
	Test.assert(equalAmounts(a: actualYieldUnits, b: 615.38461539, tolerance: 0.0000001), message: "Yield mismatch at step 0")
	Test.assert(equalAmounts(a: actualCollateral, b: 1000.00000000, tolerance: 0.0000001), message: "Collateral mismatch at step 0")

	// Step 1: after FLOW
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.50000000)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
	actualDebt = getMOETDebtFromPosition(pid: pid)
	actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
	flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
	actualCollateral = flowCollateralAmount * 0.50000000
	logStep("Scenario3_Path_D", 1, actualDebt, 307.69230769, actualYieldUnits, 307.69230769, actualCollateral, 500.00000000)
	Test.assert(equalAmounts(a: actualDebt, b: 307.69230769, tolerance: 0.0000001), message: "Debt mismatch at step 1")
	Test.assert(equalAmounts(a: actualYieldUnits, b: 307.69230769, tolerance: 0.0000001), message: "Yield mismatch at step 1")
	Test.assert(equalAmounts(a: actualCollateral, b: 500.00000000, tolerance: 0.0000001), message: "Collateral mismatch at step 1")

	// Step 2: after YIELD
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.50000000)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.50000000)
	rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
	actualDebt = getMOETDebtFromPosition(pid: pid)
	actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
	flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
	actualCollateral = flowCollateralAmount * 0.50000000
	logStep("Scenario3_Path_D", 2, actualDebt, 402.36686391, actualYieldUnits, 268.24457594, actualCollateral, 653.84615385)
	Test.assert(equalAmounts(a: actualDebt, b: 402.36686391, tolerance: 0.0000001), message: "Debt mismatch at step 2")
	Test.assert(equalAmounts(a: actualYieldUnits, b: 268.24457594, tolerance: 0.0000001), message: "Yield mismatch at step 2")
	Test.assert(equalAmounts(a: actualCollateral, b: 653.84615385, tolerance: 0.0000001), message: "Collateral mismatch at step 2")
	closeTide(signer: user, id: tideIDs![0], beFailed: false)
	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
}