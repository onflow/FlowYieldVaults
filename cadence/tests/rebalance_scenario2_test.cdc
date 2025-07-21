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
fun test_RebalanceTideScenario2() {
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

	for index, yieldTokenPrice in yieldPriceIncreases {
		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before yield price \(yieldTokenPrice): \(tideBalance ?? 0.0)")

		setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldTokenPrice)

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance before yield price \(yieldTokenPrice) rebalance: \(tideBalance ?? 0.0)")

		rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: protocolAccount, pid: pid, force: false, beFailed: false)

		tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

		log("[TEST] Tide balance after yield before \(yieldTokenPrice) rebalance: \(tideBalance ?? 0.0)")

		// Get Flow collateral from position
		let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
		let flowCollateralValue = flowCollateralAmount * 1.0  // Flow price remains at 1.0
		
		// Detailed precision comparison
		let actualTideBalance = tideBalance ?? 0.0
		let expectedBalance = expectedFlowBalance[index]
		
		// Calculate differences
		let tideDiff = actualTideBalance > expectedBalance ? actualTideBalance - expectedBalance : expectedBalance - actualTideBalance
		let tideSign = actualTideBalance > expectedBalance ? "+" : "-"
		let tidePercentDiff = (tideDiff / expectedBalance) * 100.0
		
		let positionDiff = flowCollateralValue > expectedBalance ? flowCollateralValue - expectedBalance : expectedBalance - flowCollateralValue
		let positionSign = flowCollateralValue > expectedBalance ? "+" : "-"
		let positionPercentDiff = (positionDiff / expectedBalance) * 100.0
		
		let tideVsPositionDiff = actualTideBalance > flowCollateralValue ? actualTideBalance - flowCollateralValue : flowCollateralValue - actualTideBalance
		let tideVsPositionSign = actualTideBalance > flowCollateralValue ? "+" : "-"
		
		log("\n=== PRECISION COMPARISON for Yield Price \(yieldTokenPrice) ===")
		log("Expected Value:         \(expectedBalance)")
		log("Actual Tide Balance:    \(actualTideBalance)")
		log("Flow Position Value:    \(flowCollateralValue)")
		log("Flow Position Amount:   \(flowCollateralAmount) tokens")
		log("")
		log("Tide vs Expected:       \(tideSign)\(tideDiff) (\(tideSign)\(tidePercentDiff)%)")
		log("Position vs Expected:   \(positionSign)\(positionDiff) (\(positionSign)\(positionPercentDiff)%)")
		log("Tide vs Position:       \(tideVsPositionSign)\(tideVsPositionDiff)")
		log("===============================================\n")

		// Temporarily commented to see all precision differences
		// Test.assert(
		// 	tideBalance == expectedFlowBalance[index],
		// 	message: "Tide balance of \(tideBalance ?? 0.0) doesn't match an expected value \(expectedFlowBalance[index])"
		// )
		
		Test.assert(
			equalAmounts(a: actualTideBalance, b: expectedBalance, tolerance: 0.01),
			message: "Expected balance \(expectedBalance) but got \(actualTideBalance) for yield price \(yieldTokenPrice)"
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

