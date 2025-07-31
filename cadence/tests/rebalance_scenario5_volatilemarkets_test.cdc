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

// Helper function to get MOET debt from position
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            // Debit means it's a borrow (debt)
            if balance.direction.rawValue == 1 {  // Debit = 1
                return balance.balance
            }
        }
    }
    return 0.0
}

// Helper function to get Yield tokens from position 
access(all) fun getYieldTokensFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@YieldToken.Vault>() {
            // Credit means it's a deposit
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

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

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_RebalanceTideScenario5_VolatileMarkets() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0

	let user = Test.createAccount()

	let flowPrices = [1.00000000, 1.80000000, 0.60000000, 2.20000000, 0.40000000, 3.00000000, 1.00000000, 0.20000000, 4.00000000, 1.50000000]
	let yieldPrices = [1.00000000, 1.20000000, 1.50000000, 1.50000000, 2.50000000, 2.50000000, 3.50000000, 3.50000000, 4.00000000, 4.00000000]
	
	// Expected values from CSV
	let expectedDebts = [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692]
	let expectedYieldUnits = [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673]
	let expectedCollaterals = [1000.00000000, 1923.07692308, 936.88362919, 3435.23997370, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375]

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

	testSnapshot = getCurrentBlockHeight()

	for i, flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before flow price \(flowPrice) \(tideBalance ?? 0.0)")

		setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)
		setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before rebalance: \(tideBalance ?? 0.0)")

		rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
		rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance after rebalance: \(tideBalance ?? 0.0)")

		// Get actual values from position
		let actualDebt = getMOETDebtFromPosition(pid: pid)
		// Get yield tokens from auto-balancer, not position
		let actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
		// Get tide balance (FLOW amount) and convert to USD value
		let tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0]) ?? 0.0
		let actualCollateral = tideBalance * flowPrice  // Convert FLOW to USD
        
		// Log comparison
		log("\n=== Step \(i) - Flow: \(flowPrice), Yield: \(yieldPrices[i]) ===")
		log("Expected - Debt: \(expectedDebts[i]), Yield: \(expectedYieldUnits[i]), Collateral: \(expectedCollaterals[i])")
		log("Actual   - Debt: \(actualDebt), Yield: \(actualYieldUnits), Collateral: \(actualCollateral)")
		
		// Calculate diffs
		let debtDiff = actualDebt > expectedDebts[i] ? actualDebt - expectedDebts[i] : expectedDebts[i] - actualDebt
		let collDiff = actualCollateral > expectedCollaterals[i] ? actualCollateral - expectedCollaterals[i] : expectedCollaterals[i] - actualCollateral
		
		log("Debt Diff: \(debtDiff)")
		log("Collateral Diff: \(collDiff)")

		// Assertions with tolerance
		// Note: Debt values may have slight precision differences due to protocol calculations
		Test.assert(
			equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 1.5),
			message: "Debt mismatch at step \(i): expected \(expectedDebts[i]) but got \(actualDebt)"
		)
		
		// Primary check on collateral (matching existing test behavior)
		// Note: Scenario 2 may have slightly different collateral values due to complex rebalancing
		Test.assert(
			equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 2.5),
			message: "Collateral mismatch at step \(i): expected \(expectedCollaterals[i]) but got \(actualCollateral)"
		)
	}

	closeTide(signer: user, id: tideIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")

	Test.assert(
		(flowBalanceAfter-flowBalanceBefore) > 0.1,
		message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	)
}
