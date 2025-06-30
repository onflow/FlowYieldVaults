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
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, /storage/flowTokenVault, true],
        borrowUser
    )
    Test.expect(txRes, Test.beSucceeded())
    
    // Track the actual position ID (will be 1 if setup() created position 0)
    let userPositionID: UInt64 = 1
    log("Using position ID: ".concat(userPositionID.toString()))
    
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
    
    // Define mixed price scenarios
    let flowPrices: [UFix64] = [1.0, 0.5, 1.5, 0.3, 2.0, 1.0, 0.1, 1.0]
    let yieldPrices: [UFix64] = [1.0, 1.2, 0.8, 0.5, 2.0, 0.1, 1.0, 1.0]
    let moetPrices: [UFix64] = [1.0, 1.0, 1.0, 0.95, 1.0, 1.0, 0.9, 1.0]  // Adding MOET depeg scenarios
    let descriptions: [String] = [
        "Baseline",
        "FLOW crash, YieldToken rise", 
        "FLOW rise, YieldToken drop",
        "Both crash (MOET slightly depegged)",
        "Both moon",
        "FLOW stable, YieldToken crash",
        "FLOW crash, YieldToken stable (MOET depegged)",
        "Return to baseline"
    ]
    
    var i = 0
    while i < flowPrices.length {
        let flowPrice = flowPrices[i]
        let yieldPrice = yieldPrices[i]
        let moetPrice = moetPrices[i]
        let description = descriptions[i]
        
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(description))
        
        // Update all prices
        setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: flowPrice, tokenName: "FLOW")
        setMockOraclePriceWithLog(signer: tidalYieldAccount, forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: yieldPrice, tokenName: "YieldToken")
        if moetPrice != 1.0 {
            setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: moetPrice, tokenName: "MOET")
        }
        
        // Log comprehensive state before rebalancing
        log("")
        log("==================== BEFORE REBALANCING ====================")
        
        // Get position details for comprehensive logging
        let positionDetailsBefore = getPositionDetails(pid: userPositionID, beFailed: false)
        var collateralBefore: UFix64 = 0.0
        var debtBefore: UFix64 = 0.0
        
        for bal in positionDetailsBefore.balances {
            if bal.vaultType == Type<@FlowToken.Vault>() {
                collateralBefore = bal.balance
            } else if bal.vaultType == Type<@MOET.Vault>() {
                debtBefore = bal.balance
            }
        }
        
        let healthBefore = getPositionHealth(pid: userPositionID, beFailed: false)
        let yieldBalanceBefore = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        // Log comprehensive states
        logCompatiblePositionState(pid: userPositionID, stage: "Before Rebalance", flowPrice: flowPrice, moetPrice: moetPrice)
        logCompatibleAutoBalancerState(
            id: autoBalancerID,
            tideID: tideID,
            stage: "Before Rebalance",
            flowPrice: flowPrice,
            yieldPrice: yieldPrice,
            moetPrice: moetPrice,
            initialDeposit: 1000.0
        )
        
        // Rebalance both systems
        log("")
        log("Triggering rebalances...")
        rebalancePosition(signer: protocolAccount, pid: userPositionID, force: true, beFailed: false)
        rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
        
        // Get position details after rebalance
        let positionDetailsAfter = getPositionDetails(pid: userPositionID, beFailed: false)
        var collateralAfter: UFix64 = 0.0
        var debtAfter: UFix64 = 0.0
        for bal in positionDetailsAfter.balances {
            if bal.vaultType == Type<@FlowToken.Vault>() {
                collateralAfter = bal.balance
            } else if bal.vaultType == Type<@MOET.Vault>() {
                debtAfter = bal.balance
            }
        }
        
        let healthAfter = getPositionHealth(pid: userPositionID, beFailed: false)
        let yieldBalanceAfter = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        // Log comprehensive states
        logCompatiblePositionState(pid: userPositionID, stage: "After Rebalance", flowPrice: flowPrice, moetPrice: moetPrice)
        logCompatibleAutoBalancerState(
            id: autoBalancerID,
            tideID: tideID,
            stage: "After Rebalance",
            flowPrice: flowPrice,
            yieldPrice: yieldPrice,
            moetPrice: moetPrice,
            initialDeposit: 1000.0
        )
        
        // Create state snapshots and log changes
        let beforeSnapshot = StateSnapshot(
            health: healthBefore,
            collateralAmount: collateralBefore,
            debtAmount: debtBefore,
            yieldBalance: yieldBalanceBefore,
            flowPrice: flowPrice,
            yieldPrice: yieldPrice,
            moetPrice: moetPrice
        )
        
        let afterSnapshot = StateSnapshot(
            health: healthAfter,
            collateralAmount: collateralAfter,
            debtAmount: debtAfter,
            yieldBalance: yieldBalanceAfter,
            flowPrice: flowPrice,
            yieldPrice: yieldPrice,
            moetPrice: moetPrice
        )
        
        logStateChanges(before: beforeSnapshot, after: afterSnapshot, operation: "Rebalancing")
        
        // Check for any interaction effects
        if i > 0 {
            if healthBefore < 0.5 && yieldBalanceAfter < yieldBalanceBefore {
                log("")
                log("[INTERACTION] Low borrow health may have affected available liquidity for balancer")
            }
            if yieldPrices[i-1] < 0.5 && healthAfter > healthBefore {
                log("")
                log("[INTERACTION] YieldToken crash improved borrow position (cheaper debt repayment)")
            }
            if moetPrice < 1.0 {
                log("")
                log("[INTERACTION] MOET depeg affects both systems - all values impacted")
            }
        }
        
        i = i + 1
    }
    
    // Final comprehensive summary
    logSeparator(title: "Final State Summary")
    
    let finalPositionDetails = getPositionDetails(pid: userPositionID, beFailed: false)
    var finalCollateral: UFix64 = 0.0
    var finalDebt: UFix64 = 0.0
    
    for bal in finalPositionDetails.balances {
        if bal.vaultType == Type<@FlowToken.Vault>() {
            finalCollateral = bal.balance
        } else if bal.vaultType == Type<@MOET.Vault>() {
            finalDebt = bal.balance
        }
    }
    
    let finalHealth = getPositionHealth(pid: userPositionID, beFailed: false)
    let finalYieldBalance = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    
    log("AUTO-BORROW POSITION:")
    log("  Final Health: ".concat(finalHealth.toString()))
    log("  Final Collateral: ".concat(finalCollateral.toString()).concat(" FLOW"))
    log("  Final Debt: ".concat(finalDebt.toString()).concat(" MOET"))
    log("")
    log("AUTO-BALANCER:")
    log("  Final YieldToken Balance: ".concat(finalYieldBalance.toString()))
    log("  Final Value: ".concat((finalYieldBalance * 1.0).toString()).concat(" MOET (at current price)"))
    log("")
    log("CHANGES FROM START:")
    log("  Health: 1.3 -> ".concat(finalHealth.toString()))
    log("  Collateral: 1000 -> ".concat(finalCollateral.toString()))
    log("  Debt: ~615.38 -> ".concat(finalDebt.toString()))
    log("  YieldToken: ~615.38 -> ".concat(finalYieldBalance.toString()))
} 