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
fun test_RebalanceTideScenario8_MultiStepPaths() {
    // Test multiple market paths

    
    // Path: BearMarket
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.0
        
        let flowPrices = [1.00000000, 0.90000000, 0.80000000, 0.70000000, 0.60000000, 0.50000000, 0.40000000, 0.30000000]
        let yieldPrices = [1.00000000, 1.10000000, 1.20000000, 1.30000000, 1.40000000, 1.50000000, 1.60000000, 1.70000000]
        let expectedDebts = [615.38461538, 591.71597633, 559.07274842, 517.85905222, 468.39322559, 410.91640121, 345.59122973, 272.48539268]
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(user.address.hashValue % 1000) // Unique PID
        
        for i, _ in flowPrices {
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])
            
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
            
            let actualDebt = getMOETDebtFromPosition(pid: pid)
            
            Test.assert(
                equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.01),
                message: "BearMarket debt mismatch at step \(i)"
            )
        }
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Path: BullMarket
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.0
        
        let flowPrices = [1.00000000, 1.20000000, 1.50000000, 2.00000000, 2.50000000, 3.00000000, 3.50000000, 4.00000000]
        let yieldPrices = [1.00000000, 1.00000000, 1.05000000, 1.05000000, 1.10000000, 1.10000000, 1.15000000, 1.20000000]
        let expectedDebts = [615.38461538, 738.46153846, 923.07692308, 1230.76923077, 1598.33192449, 1917.99830938, 2237.66469428, 2673.18463065]
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(user.address.hashValue % 1000) // Unique PID
        
        for i, _ in flowPrices {
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])
            
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
            
            let actualDebt = getMOETDebtFromPosition(pid: pid)
            
            Test.assert(
                equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.01),
                message: "BullMarket debt mismatch at step \(i)"
            )
        }
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Path: Sideways
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.0
        
        let flowPrices = [1.00000000, 1.10000000, 0.90000000, 1.05000000, 0.95000000, 1.02000000, 0.98000000, 1.00000000]
        let yieldPrices = [1.00000000, 1.05000000, 1.05000000, 1.10000000, 1.10000000, 1.15000000, 1.15000000, 1.20000000]
        let expectedDebts = [615.38461538, 676.92307692, 553.84615385, 682.22034376, 617.24697769, 662.72833394, 636.73898751, 684.78648552]
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(user.address.hashValue % 1000) // Unique PID
        
        for i, _ in flowPrices {
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])
            
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
            
            let actualDebt = getMOETDebtFromPosition(pid: pid)
            
            Test.assert(
                equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.01),
                message: "Sideways debt mismatch at step \(i)"
            )
        }
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

    
    // Path: Crisis
    do {
        let user = Test.createAccount()
        let fundingAmount = 1000.0
        
        let flowPrices = [1.00000000, 0.50000000, 0.20000000, 0.10000000, 0.15000000, 0.30000000, 0.70000000, 1.20000000]
        let yieldPrices = [1.00000000, 2.00000000, 5.00000000, 10.00000000, 10.00000000, 10.00000000, 10.00000000, 10.00000000]
        let expectedDebts = [615.38461538, 686.39053255, 908.14747383, 1012.93372081, 1519.40058122, 3038.80116243, 7090.53604567, 12155.20464973]
        
        mintFlow(to: user, amount: fundingAmount)
        createTide(
            signer: user,
            strategyIdentifier: strategyIdentifier,
            vaultIdentifier: flowTokenIdentifier,
            amount: fundingAmount,
            beFailed: false
        )
        
        let tideIDs = getTideIDs(address: user.address)
        let pid = UInt64(user.address.hashValue % 1000) // Unique PID
        
        for i, _ in flowPrices {
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
            setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])
            
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
            
            let actualDebt = getMOETDebtFromPosition(pid: pid)
            
            Test.assert(
                equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.01),
                message: "Crisis debt mismatch at step \(i)"
            )
        }
        
        closeTide(signer: user, id: tideIDs![0], beFailed: false)
    }

}