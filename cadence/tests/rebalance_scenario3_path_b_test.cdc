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

access(all)
fun test_RebalanceTideScenario3_Path_B() {
    // Test.reset(to: snapshot)
    
    let user = Test.createAccount()
    let fundingAmount = 1000.0
    
    // Expected values at each step
    let expectedYieldTokenValues = [615.38461538, 923.07692308, 841.14701866]
    let expectedFlowCollateralValues = [1000.00000000, 1500.00000000, 1776.92307692]
    let expectedDebtValues = [615.38461538, 923.07692308, 1093.49112426]
    
    // Price changes
    let flowPriceDecrease = 1.50000000
    let yieldPriceIncrease = 1.30000000
    
    mintFlow(to: user, amount: fundingAmount)
    
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    
    var tideIDs = getTideIDs(address: user.address)
    let pid = 1 as UInt64
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil")
    
    // Initial rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    // Step 0: Verify initial state
    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var actualCollateral = getFlowCollateralFromPosition(pid: pid) * 1.0  // Flow price is 1.0
    
    Test.assert(
        equalAmounts(a: actualDebt, b: expectedDebtValues[0], tolerance: 0.01),
        message: "Initial debt mismatch: expected \(expectedDebtValues[0]) but got \(actualDebt)"
    )
    
    // Step 1: Change flow price
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)
    
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    actualDebt = getMOETDebtFromPosition(pid: pid)
    actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    actualCollateral = getFlowCollateralFromPosition(pid: pid) * flowPriceDecrease
    
    log("\n=== After Flow Price Change to \(flowPriceDecrease) ===")
    log("Expected Debt: \(expectedDebtValues[1]), Actual: \(actualDebt)")
    log("Expected Yield: \(expectedYieldTokenValues[1]), Actual: \(actualYieldUnits)")
    log("Expected Collateral: \(expectedFlowCollateralValues[1]), Actual: \(actualCollateral)")
    
    Test.assert(
        equalAmounts(a: actualDebt, b: expectedDebtValues[1], tolerance: 0.01),
        message: "Debt mismatch after flow price change: expected \(expectedDebtValues[1]) but got \(actualDebt)"
    )
    Test.assert(
        equalAmounts(a: actualCollateral, b: expectedFlowCollateralValues[1], tolerance: 0.01),
        message: "Collateral mismatch after flow price change: expected \(expectedFlowCollateralValues[1]) but got \(actualCollateral)"
    )
    
    // Step 2: Change yield price
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)
    
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    actualDebt = getMOETDebtFromPosition(pid: pid)
    actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    actualCollateral = getFlowCollateralFromPosition(pid: pid) * flowPriceDecrease
    
    log("\n=== After Yield Price Change to \(yieldPriceIncrease) ===")
    log("Expected Debt: \(expectedDebtValues[2]), Actual: \(actualDebt)")
    log("Expected Yield: \(expectedYieldTokenValues[2]), Actual: \(actualYieldUnits)")
    log("Expected Collateral: \(expectedFlowCollateralValues[2]), Actual: \(actualCollateral)")
    
    Test.assert(
        equalAmounts(a: actualDebt, b: expectedDebtValues[2], tolerance: 1.5),
        message: "Debt mismatch after yield price change: expected \(expectedDebtValues[2]) but got \(actualDebt)"
    )
    Test.assert(
        equalAmounts(a: actualYieldUnits, b: expectedYieldTokenValues[2], tolerance: 0.01),
        message: "Yield mismatch after yield price change: expected \(expectedYieldTokenValues[2]) but got \(actualYieldUnits)"
    )
    Test.assert(
        equalAmounts(a: actualCollateral, b: expectedFlowCollateralValues[2], tolerance: 0.01),
        message: "Collateral mismatch after yield price change: expected \(expectedFlowCollateralValues[2]) but got \(actualCollateral)"
    )
    
    closeTide(signer: user, id: tideIDs![0], beFailed: false)
}
