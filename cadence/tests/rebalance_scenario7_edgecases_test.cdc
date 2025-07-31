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
fun test_RebalanceTideScenario7_EdgeCases() {
    // Test edge cases from CSV

    
    // Test Case: VeryLowFlow
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.01000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nVeryLowFlow - Debt: \(actualDebt) vs \(6.15384615)")
        log("VeryLowFlow - Yield: \(actualYield) vs \(6.15384615)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 6.15384615, tolerance: 0.01),
            message: "VeryLowFlow debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Test Case: VeryHighFlow
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 100.00000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nVeryHighFlow - Debt: \(actualDebt) vs \(61538.46153846)")
        log("VeryHighFlow - Yield: \(actualYield) vs \(61538.46153846)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 61538.46153846, tolerance: 0.01),
            message: "VeryHighFlow debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Test Case: VeryHighYield
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.00000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 50.00000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nVeryHighYield - Debt: \(actualDebt) vs \(19171.59763315)")
        log("VeryHighYield - Yield: \(actualYield) vs \(383.43195266)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 19171.59763315, tolerance: 0.01),
            message: "VeryHighYield debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Test Case: BothVeryLow
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.05000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 0.02000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nBothVeryLow - Debt: \(actualDebt) vs \(30.76923077)")
        log("BothVeryLow - Yield: \(actualYield) vs \(-28615.38461542)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 30.76923077, tolerance: 0.01),
            message: "BothVeryLow debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Test Case: MinimalPosition
    do {
        let user = Test.createAccount()
        let fundingAmount = 1.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.00000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nMinimalPosition - Debt: \(actualDebt) vs \(0.61538461)")
        log("MinimalPosition - Yield: \(actualYield) vs \(0.61538461)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 0.61538461, tolerance: 0.01),
            message: "MinimalPosition debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Test Case: LargePosition
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000000.00000000
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(tideIDs!.length) // Unique PID for each test
        
        // Set extreme prices
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.00000000)
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.00000000)
        
        // Rebalance
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        
        // Verify
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        
        log("\nLargePosition - Debt: \(actualDebt) vs \(615384.61538462)")
        log("LargePosition - Yield: \(actualYield) vs \(615384.61538462)")
        
        Test.assert(
            equalAmounts(a: actualDebt, b: 615384.61538462, tolerance: 0.01),
            message: "LargePosition debt mismatch"
        )
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

}