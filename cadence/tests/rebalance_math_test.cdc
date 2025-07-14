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

// Helper function to get detailed position info
access(all) fun getDetailedPositionInfo(pid: UInt64): {String: AnyStruct} {
    let res = executeScript(
        "../scripts/tidal-protocol/position_details.cdc",
        [pid]
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! {String: AnyStruct}
}

// Helper function to get tide details
access(all) fun getTideDetails(tideID: UInt64): {String: AnyStruct} {
    let balance = getTideBalance(address: Test.createAccount().address, tideID: tideID) ?? 0.0
    let yieldTokens = getAutoBalancerBalance(id: tideID) ?? 0.0
    let currentValue = getAutoBalancerCurrentValue(id: tideID) ?? 0.0
    
    return {
        "tideBalance": balance,
        "yieldTokens": yieldTokens,
        "currentValue": currentValue
    }
}

// Helper function to get tide details for a specific user
access(all) fun getTideDetailsForUser(address: Address, tideID: UInt64): {String: AnyStruct} {
    let balance = getTideBalance(address: address, tideID: tideID) ?? 0.0
    let yieldTokens = getAutoBalancerBalance(id: tideID) ?? 0.0
    let currentValue = getAutoBalancerCurrentValue(id: tideID) ?? 0.0
    
    return {
        "tideBalance": balance,
        "yieldTokens": yieldTokens,
        "currentValue": currentValue
    }
}

access(all)
fun test_ComprehensiveRebalanceScenario2() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()
    
    let yieldPriceIncreases = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0]
    let expectedFlowBalance = [
        1061.53846151,
        1120.92522857,
        1178.40857358,
        1289.97388218,
        1554.58390875,
        2032.91741828
    ]
    
    // Initial setup
    mintFlow(to: user, amount: fundingAmount)
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    
    var tideIDs = getTideIDs(address: user.address)
    var pid = 1 as UInt64
    
    log("=== Initial State ===")
    log("Tide ID: \(tideIDs![0])")
    
    // Initial rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    log("\n=== After Initial Rebalance ===")
    var tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
    log("Tide Balance: \(tideDetails["tideBalance"]!)")
    log("Yield Tokens: \(tideDetails["yieldTokens"]!)")
    log("Current Value: \(tideDetails["currentValue"]!)")
    
    var positionInfo = getDetailedPositionInfo(pid: pid)
    log("Position Deposits: \(positionInfo["deposits"]!)")
    log("Position Borrows: \(positionInfo["borrows"]!)")
    log("Position Health: \(positionInfo["health"]!)")
    
    // Test each price increase
    for index, yieldTokenPrice in yieldPriceIncreases {
        log("\n=== Testing Yield Price: \(yieldTokenPrice) ===")
        
        // Before price change
        tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
        log("Before Price Change - Tide Balance: \(tideDetails["tideBalance"]!)")
        log("Before Price Change - Yield Tokens: \(tideDetails["yieldTokens"]!)")
        
        // Set new price
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldTokenPrice)
        
        // After price change, before rebalance
        tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
        log("After Price Change - Tide Balance: \(tideDetails["tideBalance"]!)")
        log("After Price Change - Current Value: \(tideDetails["currentValue"]!)")
        
        positionInfo = getDetailedPositionInfo(pid: pid)
        log("After Price Change - Position Health: \(positionInfo["health"]!)")
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: false, beFailed: false)
        
        // After rebalance
        tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
        let actualBalance = tideDetails["tideBalance"]! as! UFix64
        let expectedBalance = expectedFlowBalance[index]
        
        log("After Rebalance - Tide Balance: \(actualBalance)")
        log("After Rebalance - Expected Balance: \(expectedBalance)")
        log("After Rebalance - Difference: \(actualBalance - expectedBalance)")
        log("After Rebalance - Yield Tokens: \(tideDetails["yieldTokens"]!)")
        
        positionInfo = getDetailedPositionInfo(pid: pid)
        log("After Rebalance - Position Deposits: \(positionInfo["deposits"]!)")
        log("After Rebalance - Position Borrows: \(positionInfo["borrows"]!)")
        log("After Rebalance - Position Health: \(positionInfo["health"]!)")
        
        // Check if within acceptable precision range (0.00001% tolerance)
        let tolerance = expectedBalance * 0.0000001
        Test.assert(
            (actualBalance >= expectedBalance - tolerance) && (actualBalance <= expectedBalance + tolerance),
            message: "Tide balance \(actualBalance) outside acceptable range [\(expectedBalance - tolerance), \(expectedBalance + tolerance)]"
        )
    }
    
    // Close tide and check final balance
    closeTide(signer: user, id: tideIDs![0], beFailed: false)
    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("\n=== Final Flow Balance: \(flowBalanceAfter) ===")
}

access(all)
fun test_ComprehensiveRebalanceScenario3A() {
    let fundingAmount = 1000.0
    let flowPriceDecrease = 0.8
    let yieldPriceIncrease = 1.2
    let expectedYieldTokenValues = [615.38, 492.31, 460.75]
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    
    var tideIDs = getTideIDs(address: user.address)
    var pid = 1 as UInt64
    
    log("=== Scenario 3A: Flow Price Decrease then Yield Price Increase ===")
    
    // Initial rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    var tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
    log("\nAfter Initial Rebalance:")
    log("Tide Balance: \(tideDetails["tideBalance"]!)")
    log("Yield Tokens: \(tideDetails["yieldTokens"]!)")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
    
    // Flow price decrease
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)
    
    log("\nAfter Flow Price Change to \(flowPriceDecrease):")
    var positionInfo = getDetailedPositionInfo(pid: pid)
    log("Position Health Before Rebalance: \(positionInfo["health"]!)")
    
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    
    tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
    log("After Rebalance - Yield Tokens: \(tideDetails["yieldTokens"]!)")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
    
    // Yield price increase
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)
    
    log("\nAfter Yield Price Change to \(yieldPriceIncrease):")
    positionInfo = getDetailedPositionInfo(pid: pid)
    log("Position Health Before Rebalance: \(positionInfo["health"]!)")
    
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    
    tideDetails = getTideDetailsForUser(address: user.address, tideID: tideIDs![0])
    log("After Rebalance - Yield Tokens: \(tideDetails["yieldTokens"]!)")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
    
    closeTide(signer: user, id: tideIDs![0], beFailed: false)
} 