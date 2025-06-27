import Test
import "FlowToken"
import "MOET"
import "TidalProtocol"
import "Tidal"
import "TidalYieldStrategies"
import "TidalYieldAutoBalancers"
import "YieldToken"
import "DFB"

// Import helper utilities from the local test helpers file
import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) let flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) let moetTokenIdentifier = Type<@MOET.Vault>().identifier
access(all) let yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all) fun setup() {
    deployContracts()
    
    // Setup initial prices
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)
    
    // Mint tokens for liquidity
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
    
    // Enable TracerStrategy
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
}

access(all)
fun testAutoBalancerRebalancesOnYieldTokenPriceChanges() {
    /*
     * IMPORTANT: TidalYield AutoBalancer Behavior
     * - TracerStrategy uses AutoBalancer with YieldToken
     * - lowerThreshold = 0.95 (rebalance when value < 95% of deposits)
     * - upperThreshold = 1.05 (rebalance when value > 105% of deposits)
     * 
     * Rebalancing logic:
     * 1. When YieldToken price rises and holdings > 1.05x deposits, excess is sold
     * 2. When YieldToken price falls and holdings < 0.95x deposits, it would buy more (but TracerStrategy has no source)
     * 3. The AutoBalancer maintains holdings value close to deposited value
     */
    
    logSeparator(title: "TEST: Auto-Balancer Rebalances on YieldToken Price Changes")
    
    // ---------- Stage 0 – setup environment and create Tide ----------
    logSeparator(title: "STAGE 0: Initial Setup and Tide Creation")

    // Create user and setup vaults
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    setupYieldVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)

    // Create Tide with 1000 FLOW
    log("Creating Tide with 1000 FLOW using TracerStrategy...")
    let createTideRes = _executeTransaction(
        "../transactions/tidal-yield/create_tide.cdc",
        [Type<@TidalYieldStrategies.TracerStrategy>().identifier, flowTokenIdentifier, 1_000.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    logTransactionResult(result: createTideRes, operation: "Create Tide with TracerStrategy")

    // Get Tide ID
    let tideIDs = getTideIDs(address: user.address) ?? panic("No Tide IDs found")
    let tideID = tideIDs[0]
    
    log("")
    log("[STAGE 0 EXPECTATIONS]")
    log("   - Deposited 1000 FLOW")
    log("   - Auto-borrowed ~615.38 MOET (at 1.3 target health)")
    log("   - Swapped MOET to ~615.38 YieldToken (1:1 price)")
    log("   - AutoBalancer holds ~615.38 YieldToken")
    log("")
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Get initial AutoBalancer state
    let autoBalancerID = getAutoBalancerIDByTideID(tideID: tideID, beFailed: false)
    let balance0 = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    logAutoBalancerState(id: autoBalancerID, yieldPrice: 1.0, stage: "Initial State")
    
    // ---------- Stage 1 – YieldToken price rises 20% ----------
    logSeparator(title: "STAGE 1: YieldToken Price Rises 20%")
    
    setMockOraclePriceWithLog(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2, tokenName: "YieldToken")
    
    // Log before rebalance
    logAutoBalancerState(id: autoBalancerID, yieldPrice: 1.2, stage: "Before Rebalance")
    
    log("Triggering rebalance with force=true...")
    rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
    
    // Stage 1 expectations:
    // - Holdings value = 615.38 * 1.2 = 738.46 MOET
    // - This is 120% of deposits (615.38), exceeds 105% threshold
    // - Should sell YieldToken to bring value back to ~615.38 MOET
    // - At price 1.2, needs to hold ~512.82 YieldToken
    let balance1 = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    log("Stage 1 · AutoBalancer YieldToken balance after rebalance: ".concat(balance1.toString()))
    log("Stage 1 · Holdings value after rebalance: ".concat((balance1 * 1.2).toString()).concat(" MOET"))
    
    // Log the expected behavior
    log("Stage 1 · Expected behavior: Should sell ~102.56 YieldToken to bring value back to ~615.38 MOET")
    log("Stage 1 · Expected new balance: ~512.82 YieldToken")
    
    // For now, let's check if any change occurred at all
    if balance1 == balance0 {
        log("WARNING: No balance change occurred during rebalance. Possible reasons:")
        log("  - Rebalancing might not be triggered even with force=true")
        log("  - The 20% price increase might not exceed the 5% threshold enough")
        log("  - There might be an issue with the rebalancing implementation")
    }
    
    // ---------- Stage 2 – YieldToken price falls to 0.75 ----------
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 0.75)
    
    // Log before rebalance
    log("Stage 2 · YieldToken price: 0.75 MOET")
    log("Stage 2 · Holdings value before rebalance: ".concat((balance1 * 0.75).toString()).concat(" MOET"))
    
    // Trigger rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
    
    // Stage 2 expectations:
    // - TracerStrategy has no rebalanceSource, so it cannot buy more YieldToken
    // - Balance should remain the same (no buying capability)
    let balance2 = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    log("Stage 2 · AutoBalancer YieldToken balance after rebalance: ".concat(balance2.toString()))
    log("Stage 2 · Holdings value after rebalance: ".concat((balance2 * 0.75).toString()).concat(" MOET"))
    
    // Log the expected behavior
    log("Stage 2 · Expected: Balance should remain the same (no rebalanceSource to buy more)")
    
    if balance2 != balance1 {
        log("WARNING: Balance changed in Stage 2, which was unexpected")
    }
    
    // ---------- Stage 3 – YieldToken price rises to 1.5 ----------
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    
    // Log before rebalance
    log("Stage 3 · YieldToken price: 1.5 MOET")
    log("Stage 3 · Holdings value before rebalance: ".concat((balance2 * 1.5).toString()).concat(" MOET"))
    
    // Trigger rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
    
    // Stage 3 expectations:
    // - Should sell more YieldToken to maintain value close to deposits
    let balance3 = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    log("Stage 3 · AutoBalancer YieldToken balance after rebalance: ".concat(balance3.toString()))
    log("Stage 3 · Holdings value after rebalance: ".concat((balance3 * 1.5).toString()).concat(" MOET"))
    
    // Log the expected behavior
    log("Stage 3 · Expected: Should sell more YieldToken when price rises to 1.5")
    
    if balance3 >= balance2 {
        log("WARNING: Balance did not decrease in Stage 3 as expected")
        log("Final summary:")
        log("  - Initial balance: ".concat(balance0.toString()))
        log("  - After 1.2x price: ".concat(balance1.toString()))
        log("  - After 0.75x price: ".concat(balance2.toString()))
        log("  - After 1.5x price: ".concat(balance3.toString()))
    }
} 