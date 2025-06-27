import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"
import "Tidal"
import "TidalYieldStrategies"
import "TidalYieldAutoBalancers"
import "YieldToken"
import "DFB"

// Import helper utilities
import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) let flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) let moetTokenIdentifier = Type<@MOET.Vault>().identifier
access(all) let yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) let flowVaultStoragePath = /storage/flowTokenVault

// Price scenario structure
access(all) struct PriceScenario {
    access(all) let name: String
    access(all) let token: String
    access(all) let prices: [UFix64]
    access(all) let descriptions: [String]
    
    init(name: String, token: String, prices: [UFix64], descriptions: [String]) {
        self.name = name
        self.token = token
        self.prices = prices
        self.descriptions = descriptions
    }
}

access(all) fun setup() {
    deployContracts()
    
    // Setup initial prices
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)
    
    // Setup liquidity and pools
    let reserveAmount = 100_000.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    
    // Setup liquidity connectors
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)
    
    // Setup TidalProtocol pool
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    
    // Create wrapped position for reserves
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())
}

// Run a price scenario for auto-borrow positions
access(all)
fun runAutoBorrowPriceScenario(scenario: PriceScenario) {
    logSeparator(title: "AUTO-BORROW SCENARIO: ".concat(scenario.name))
    
    // Create user and position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    
    // Reset prices to baseline
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0, tokenName: "FLOW")
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0, tokenName: "MOET")
    
    // Create position with auto-borrow
    log("Creating position with 1000 FLOW...")
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(txRes, Test.beSucceeded())
    
    let initialHealth = getPositionHealth(pid: 0, beFailed: false)
    log("Initial position health: ".concat(initialHealth.toString()))
    
    // Run through price scenarios
    var i = 0
    for price in scenario.prices {
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(scenario.descriptions[i]))
        
        // Update price
        setMockOraclePriceWithLog(
            signer: protocolAccount, 
            forTokenIdentifier: flowTokenIdentifier, 
            price: price, 
            tokenName: scenario.token
        )
        
        // Show position state before rebalance
        let healthBefore = getPositionHealth(pid: 0, beFailed: false)
        log("Health before rebalance: ".concat(healthBefore.toString()))
        
        // Rebalance
        log("Triggering rebalance...")
        rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
        
        // Show position state after rebalance
        let healthAfter = getPositionHealth(pid: 0, beFailed: false)
        log("Health after rebalance: ".concat(healthAfter.toString()))
        
        logPositionDetails(pid: 0, stage: "After price = ".concat(price.toString()))
        
        i = i + 1
    }
}

// Run a price scenario for auto-balancer
access(all)
fun runAutoBalancerPriceScenario(scenario: PriceScenario, strategyIdentifier: String) {
    logSeparator(title: "AUTO-BALANCER SCENARIO: ".concat(scenario.name))
    
    // Enable TracerStrategy
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
    
    // Create user and setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    setupYieldVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    
    // Create Tide
    log("Creating Tide with TracerStrategy...")
    let createTideRes = _executeTransaction(
        "../transactions/tidal-yield/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 1_000.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address) ?? panic("No Tide IDs found")
    let tideID = tideIDs[0]
    let autoBalancerID = getAutoBalancerIDByTideID(tideID: tideID, beFailed: false)
    
    let initialBalance = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    log("Initial AutoBalancer balance: ".concat(initialBalance.toString()).concat(" YieldToken"))
    
    // Run through price scenarios
    var i = 0
    for price in scenario.prices {
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(scenario.descriptions[i]))
        
        // Update price
        setMockOraclePriceWithLog(
            signer: tidalYieldAccount, 
            forTokenIdentifier: yieldTokenIdentifier, 
            price: price, 
            tokenName: scenario.token
        )
        
        // Show state before rebalance
        logAutoBalancerState(id: autoBalancerID, yieldPrice: price, stage: "Before Rebalance")
        
        // Rebalance
        log("Triggering rebalance...")
        rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
        
        // Show state after rebalance
        let balanceAfter = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        logAutoBalancerState(id: autoBalancerID, yieldPrice: price, stage: "After Rebalance")
        
        // Calculate and show change
        if balanceAfter != initialBalance {
            let change = safeSubtract(a: balanceAfter, b: initialBalance, context: "balance change")
            if balanceAfter > initialBalance {
                log("Balance INCREASED by: ".concat(change.toString()))
            } else {
                log("Balance DECREASED by: ".concat(safeSubtract(a: initialBalance, b: balanceAfter, context: "balance decrease").toString()))
            }
        } else {
            log("Balance UNCHANGED")
        }
        
        i = i + 1
    }
}

access(all)
fun testExtremePriceMovements() {
    // Test extreme FLOW price movements
    let extremeFlowScenario = PriceScenario(
        name: "Extreme FLOW Price Volatility",
        token: "FLOW",
        prices: [0.5, 0.1, 2.0, 5.0, 0.25, 1.0],
        descriptions: [
            "FLOW drops 50% to 0.5",
            "FLOW crashes 90% to 0.1", 
            "FLOW recovers to 2.0 (2x original)",
            "FLOW moons to 5.0 (5x original)",
            "FLOW crashes back to 0.25",
            "FLOW stabilizes at 1.0"
        ]
    )
    
    runAutoBorrowPriceScenario(scenario: extremeFlowScenario)
}

access(all)
fun testGradualPriceChanges() {
    // Test gradual YieldToken price changes
    let gradualYieldScenario = PriceScenario(
        name: "Gradual YieldToken Price Changes",
        token: "YieldToken",
        prices: [1.1, 1.2, 1.3, 1.4, 1.5, 1.3, 1.1, 0.9, 0.7, 0.5],
        descriptions: [
            "YieldToken +10% to 1.1",
            "YieldToken +20% to 1.2",
            "YieldToken +30% to 1.3",
            "YieldToken +40% to 1.4",
            "YieldToken +50% to 1.5",
            "YieldToken drops to 1.3",
            "YieldToken drops to 1.1",
            "YieldToken drops to 0.9",
            "YieldToken drops to 0.7",
            "YieldToken drops to 0.5"
        ]
    )
    
    runAutoBalancerPriceScenario(
        scenario: gradualYieldScenario,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier
    )
}

access(all)
fun testVolatilePriceSwings() {
    // Test volatile price swings
    let volatileScenario = PriceScenario(
        name: "Volatile Price Swings",
        token: "FLOW",
        prices: [1.5, 0.7, 1.8, 0.4, 1.2, 0.9, 2.5, 0.3, 1.0],
        descriptions: [
            "FLOW pumps to 1.5",
            "FLOW dumps to 0.7",
            "FLOW pumps to 1.8",
            "FLOW crashes to 0.4",
            "FLOW recovers to 1.2",
            "FLOW drops to 0.9",
            "FLOW moons to 2.5",
            "FLOW crashes to 0.3",
            "FLOW stabilizes at 1.0"
        ]
    )
    
    runAutoBorrowPriceScenario(scenario: volatileScenario)
} 