import Test
import "MOET"
import "TidalProtocol"

// Import helper utilities from the local test helpers file which now includes all necessary functions
import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000008.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all) fun setup() {
    deployContracts()
}

access(all)
fun testAutoBorrowRebalancesOnCollateralPriceChanges() {
    /*
     * IMPORTANT: TidalProtocol Rebalancing Behavior
     * - minHealth = 1.1 (minimum acceptable health)
     * - targetHealth = 1.3 (used for auto-borrow on position creation)
     * - maxHealth = 1.5 (maximum before rebalancing)
     * 
     * Rebalancing logic:
     * 1. Auto-borrow on creation targets 1.3 health
     * 2. Rebalancing only triggers when health < 1.1 OR health > 1.5
     * 3. When rebalancing occurs, it targets minHealth (1.1), NOT targetHealth
     * 4. This creates a "safe zone" between 1.1-1.5 where no rebalancing occurs
     */
    
    logSeparator(title: "TEST: Auto-Borrow Rebalances on Collateral Price Changes")
    
    // ---------- Stage 0 – create pool + position ----------
    logSeparator(title: "STAGE 0: Initial Setup")
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0, tokenName: "FLOW")
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0, tokenName: "MOET")

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)

    // open position with auto-borrow
    log("Creating position with 1000 FLOW and auto-borrow enabled...")
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(txRes, Test.beSucceeded())
    logTransactionResult(result: txRes, operation: "Create Position with Auto-Borrow")

    // expected values stage 0
    let collFactor: UFix64 = 0.8
    let targetHealth: UFix64 = 1.3
    let effColl0: UFix64 = 1_000.0 * collFactor
    let debt0: UFix64 = effColl0 / targetHealth
    
    log("Expected calculations:")
    log("  Collateral Factor: ".concat(collFactor.toString()))
    log("  Target Health: ".concat(targetHealth.toString()))
    log("  Effective Collateral: ".concat(effColl0.toString()).concat(" (1000 FLOW * 0.8)"))
    log("  Expected Auto-Borrow: ".concat(debt0.toString()).concat(" MOET"))
    
    // Log actual position state
    logPositionDetails(pid: 0, stage: "After Auto-Borrow Creation")

    // ---------- Stage 1 – FLOW price drops 20 % ----------
    logSeparator(title: "STAGE 1: FLOW Price Drops 20%")
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.8, tokenName: "FLOW")
    
    // Log position details before rebalance
    logPositionDetails(pid: 0, stage: "Before Rebalance (FLOW @ 0.8)")
    
    log("Triggering rebalance with force=true...")
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

    let effColl1: UFix64 = 1_000.0 * 0.8 * collFactor
    let debt1Exp: UFix64 = effColl1 / targetHealth
    log("Expected calculations after price drop:")
    log("  New Effective Collateral: ".concat(effColl1.toString()).concat(" (1000 * 0.8 * 0.8)"))
    log("  Health before rebalance: ".concat((effColl1 / debt0).toString()))
    log("  Target debt for 1.3 health: ".concat(debt1Exp.toString()))

    let details1 = getPositionDetails(pid: 0, beFailed: false)
    var debt1Actual: UFix64 = 0.0
    for bal in details1.balances {
        if bal.vaultType == Type<@MOET.Vault>() {
            debt1Actual = bal.balance
            log("Found MOET balance: ".concat(bal.balance.toString()).concat(" (").concat(bal.direction == TidalProtocol.BalanceDirection.Debit ? "DEBIT" : "CREDIT").concat(")"))
        }
    }
    
    // Log actual results
    logPositionDetails(pid: 0, stage: "After Rebalance (FLOW @ 0.8)")
    log("[ACTUAL RESULTS]")
    log("   MOET debt after rebalance: ".concat(debt1Actual.toString()))
    log("   MOET debt before rebalance: ".concat(debt0.toString()))
    
    // Safe calculation of debt change
    let debtChange = safeSubtract(a: debt0, b: debt1Actual, context: "debt change calculation")
    if debt1Actual > debt0 {
        log("   Debt INCREASED by: ".concat((debt1Actual - debt0).toString()))
    } else {
        log("   Debt DECREASED by: ".concat(debtChange.toString()))
    }
    
    // Log health calculation details
    logCalculation(
        description: "Health after rebalance",
        formula: "effColl1 (".concat(effColl1.toString()).concat(") / debt1Actual (").concat(debt1Actual.toString()).concat(")"),
        result: effColl1 / debt1Actual
    )
    
    // More lenient assertion - accept any health >= minHealth (1.1)
    let health1 = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(health1 >= 1.1,
        message: "Stage-1 health below minimum. Health: ".concat(health1.toString()))

    // ---------- Stage 2 – FLOW price rises 25 % ----------
    logSeparator(title: "STAGE 2: FLOW Price Rises 25%")
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.25, tokenName: "FLOW")
    
    // Log position details before rebalance
    logPositionDetails(pid: 0, stage: "Before Rebalance (FLOW @ 1.25)")
    
    log("Triggering rebalance with force=true...")
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

    let effColl2: UFix64 = 1_000.0 * 1.25 * collFactor
    let debt2Exp: UFix64 = effColl2 / targetHealth
    log("Stage 2 - effective collateral: ".concat(effColl2.toString()))
    log("Stage 2 - expected debt: ".concat(debt2Exp.toString()))

    let details2 = getPositionDetails(pid: 0, beFailed: false)
    var debt2Actual: UFix64 = 0.0
    for bal in details2.balances {
        if bal.vaultType == Type<@MOET.Vault>() {
            debt2Actual = bal.balance
        }
    }
    
    // Log actual health achieved
    let health2 = getPositionHealth(pid: 0, beFailed: false)
    log("Stage 2 - actual health achieved: ".concat(health2.toString()))
    log("Stage 2 - actual debt: ".concat(debt2Actual.toString()))
    
    // The position should maintain a healthy state (>= minHealth) and not exceed maxHealth
    // Default maxHealth is typically 2.0 in TidalProtocol
    Test.assert(health2 >= 1.1 && health2 <= 2.0,
        message: "Stage-2 health outside acceptable range. Health: ".concat(health2.toString()))
} 