import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"
import "Tidal"
import "TidalYieldStrategies"
import "TidalYieldAutoBalancers"
import "YieldToken"
import "DFB"

import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) fun setup() {
    deployContracts()
    
    // Setup initial prices and liquidity
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 1.0)
    
    let reserveAmount = 200_000.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)
    
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: Type<@FlowToken.Vault>().identifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
}

access(all) fun testMixedScenario() {
    logSeparator(title: "MIXED SCENARIO: Auto-Borrow + Auto-Balancer Simultaneous")
    
    // Create users for both systems
    let borrowUser = Test.createAccount()
    let balancerUser = Test.createAccount()
    
    // Setup both users
    setupMoetVault(borrowUser, beFailed: false)
    setupMoetVault(balancerUser, beFailed: false)
    setupYieldVault(balancerUser, beFailed: false)
    
    transferFlowTokens(to: borrowUser, amount: 1_000.0)
    transferFlowTokens(to: balancerUser, amount: 1_000.0)
    
    // Create auto-borrow position
    log("Creating auto-borrow position with 1000 FLOW...")
    let borrowTx = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, /storage/flowTokenVault, true],
        borrowUser
    )
    Test.expect(borrowTx, Test.beSucceeded())
    
    // Create auto-balancer tide
    log("Creating auto-balancer Tide with 1000 FLOW...")
    let tideTx = _executeTransaction(
        "../transactions/tidal-yield/create_tide.cdc",
        [Type<@TidalYieldStrategies.TracerStrategy>().identifier, Type<@FlowToken.Vault>().identifier, 1_000.0],
        balancerUser
    )
    Test.expect(tideTx, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: balancerUser.address) ?? panic("No Tide IDs found")
    let tideID = tideIDs[0]
    let autoBalancerID = getAutoBalancerIDByTideID(tideID: tideID, beFailed: false)
    
    // Log initial states
    logSeparator(title: "Initial State")
    let initialBorrowHealth = getPositionHealth(pid: 0, beFailed: false)
    let initialBalancerBalance = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    
    log("Auto-Borrow Position Health: ".concat(initialBorrowHealth.toString()))
    log("Auto-Balancer YieldToken Balance: ".concat(initialBalancerBalance.toString()))
    
    // Define mixed price scenarios
    let flowPrices: [UFix64] = [1.0, 0.5, 1.5, 0.3, 2.0, 1.0, 0.1, 1.0]
    let yieldPrices: [UFix64] = [1.0, 1.2, 0.8, 0.5, 2.0, 0.1, 1.0, 1.0]
    let descriptions: [String] = [
        "Baseline",
        "FLOW crash, YieldToken rise", 
        "FLOW rise, YieldToken drop",
        "Both crash",
        "Both moon",
        "FLOW stable, YieldToken crash",
        "FLOW crash, YieldToken stable",
        "Return to baseline"
    ]
    
    var i = 0
    while i < flowPrices.length {
        let flowPrice = flowPrices[i]
        let yieldPrice = yieldPrices[i]
        let description = descriptions[i]
        
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(description))
        
        // Update both prices
        setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: flowPrice, tokenName: "FLOW")
        setMockOraclePriceWithLog(signer: tidalYieldAccount, forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: yieldPrice, tokenName: "YieldToken")
        
        // Check states before rebalancing
        let borrowHealthBefore = getPositionHealth(pid: 0, beFailed: false)
        let balancerBalanceBefore = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        log("")
        log("BEFORE REBALANCING:")
        log("  Auto-Borrow Health: ".concat(borrowHealthBefore.toString()))
        log("  Auto-Balancer Balance: ".concat(balancerBalanceBefore.toString()).concat(" YieldToken"))
        
        // Trigger both rebalances
        log("")
        log("Triggering simultaneous rebalances...")
        rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
        rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
        
        // Check states after rebalancing
        let borrowHealthAfter = getPositionHealth(pid: 0, beFailed: false)
        let balancerBalanceAfter = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        log("")
        log("AFTER REBALANCING:")
        log("  Auto-Borrow Health: ".concat(borrowHealthAfter.toString()))
        log("  Auto-Balancer Balance: ".concat(balancerBalanceAfter.toString()).concat(" YieldToken"))
        
        // Calculate changes
        var healthChange: UFix64 = 0.0
        var healthImproved = false
        if borrowHealthAfter > borrowHealthBefore {
            healthChange = borrowHealthAfter - borrowHealthBefore
            healthImproved = true
        } else if borrowHealthBefore > borrowHealthAfter {
            healthChange = borrowHealthBefore - borrowHealthAfter
            healthImproved = false
        }
        var balanceChange: UFix64 = 0.0
        var balanceIncreased = false
        if balancerBalanceAfter > balancerBalanceBefore {
            balanceChange = balancerBalanceAfter - balancerBalanceBefore
            balanceIncreased = true
        } else if balancerBalanceBefore > balancerBalanceAfter {
            balanceChange = balancerBalanceBefore - balancerBalanceAfter
            balanceIncreased = false
        }
        
        log("")
        log("CHANGES:")
        if healthChange > 0.0 {
            log("  Health ".concat(healthImproved ? "IMPROVED" : "DETERIORATED").concat(" by: ".concat(healthChange.toString())))
        } else {
            log("  Health UNCHANGED")
        }
        if balanceChange > 0.0 {
            if balanceIncreased {
                log("  Balance INCREASED by: ".concat(balanceChange.toString()))
            } else {
                log("  Balance DECREASED by: ".concat(balanceChange.toString()))
            }
        } else {
            log("  Balance UNCHANGED")
        }
        
        // Check for any interaction effects
        if i > 0 {
            if borrowHealthBefore < 0.5 && balancerBalanceAfter < balancerBalanceBefore {
                log("")
                log("[INTERACTION] Low borrow health may have affected available liquidity for balancer")
            }
            if yieldPrices[i-1] < 0.5 && healthImproved {
                log("")
                log("[INTERACTION] YieldToken crash improved borrow position (cheaper debt repayment)")
            }
        }
        
        i = i + 1
    }
    
    logSeparator(title: "Final State Summary")
    log("Auto-Borrow Final Health: ".concat(getPositionHealth(pid: 0, beFailed: false).toString()))
    log("Auto-Balancer Final Balance: ".concat(getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false).toString()))
    log("")
    log("Initial vs Final:")
    log("  Borrow Health: ".concat(initialBorrowHealth.toString()).concat(" -> ").concat(getPositionHealth(pid: 0, beFailed: false).toString()))
    log("  Balancer Balance: ".concat(initialBalancerBalance.toString()).concat(" -> ").concat(getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false).toString()))
} 