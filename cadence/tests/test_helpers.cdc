import Test

import "MOET"
import "TidalProtocol"

/* --- Test execution helpers --- */

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

access(all)
fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )    
    return Test.executeTransaction(txn)
}

/* --- Setup helpers --- */

// Common test setup function that deploys all required contracts
access(all) fun deployContracts() {
    // DeFiBlocks contracts
    var err = Test.deployContract(
        name: "DFBUtils",
        path: "../../lib/DeFiBlocks/cadence/contracts/utils/DFBUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DFB",
        path: "../../lib/DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "SwapStack",
        path: "../../lib/DeFiBlocks/cadence/contracts/connectors/SwapStack.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "FungibleTokenStack",
        path: "../../lib/DeFiBlocks/cadence/contracts/connectors/FungibleTokenStack.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // TidalProtocol contracts
    let initialMoetSupply = 0.0
    err = Test.deployContract(
        name: "MOET",
        path: "../../lib/TidalProtocol/cadence/contracts/MOET.cdc",
        arguments: [initialMoetSupply]
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../../lib/TidalProtocol/cadence/contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Mocked contracts
    let initialYieldSupply = 0.0
    err = Test.deployContract(
        name: "YieldToken",
        path: "../contracts/mocks/YieldToken.cdc",
        arguments: [initialYieldSupply]
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [Type<@MOET.Vault>().identifier]
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "MockSwapper",
        path: "../contracts/mocks/MockSwapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockTidalProtocolConsumer",
        path: "../contracts/mocks/MockTidalProtocolConsumer.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // TidalYield contracts
    err = Test.deployContract(
        name: "TidalYieldAutoBalancers",
        path: "../contracts/TidalYieldAutoBalancers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "Tidal",
        path: "../contracts/Tidal.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "TidalYieldStrategies",
        path: "../contracts/TidalYieldStrategies.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Mocked Strategy
    err = Test.deployContract(
        name: "MockStrategy",
        path: "../contracts/mocks/MockStrategy.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun setupTidalProtocol(signer: Test.TestAccount) {
    let res = _executeTransaction("../transactions/tidal-protocol/create_and_store_pool.cdc",
            [],
            signer
        )
}

/* --- Script helpers */

access(all)
fun getBalance(address: Address, vaultPublicPath: PublicPath): UFix64? {
    let res = _executeScript("../scripts/tokens/get_balance.cdc", [address, vaultPublicPath])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

access(all)
fun getReserveBalance(vaultIdentifier: String): UFix64 {
    let res = _executeScript("../../lib/TidalProtocol/cadence/scripts/tidal-protocol/get_reserve_balance_for_type.cdc", [vaultIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getTideIDs(address: Address): [UInt64]? {
    let res = _executeScript("../scripts/tidal-yield/get_tide_ids.cdc", [address])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! [UInt64]?
}

access(all)
fun getTideBalance(address: Address, tideID: UInt64): UFix64? {
    let res = _executeScript("../scripts/tidal-yield/get_tide_balance.cdc", [address, tideID])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

/* --- Transaction Helpers --- */

access(all)
fun createAndStorePool(signer: Test.TestAccount, defaultTokenIdentifier: String, beFailed: Bool) {
    let createRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-factory/create_and_store_pool.cdc",
        [defaultTokenIdentifier],
        signer
    )
    Test.expect(createRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun addSupportedTokenSimpleInterestCurve(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
) {
    let additionRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, depositRate, depositCapacityCap ],
        signer
    )
    Test.expect(additionRes, Test.beSucceeded())
}

access(all)
fun rebalancePosition(signer: Test.TestAccount, pid: UInt64, force: Bool, beFailed: Bool) {
    let rebalanceRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/rebalance_position.cdc",
        [ pid, force ],
        signer
    )
    Test.expect(rebalanceRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun setupMoetVault(_ signer: Test.TestAccount, beFailed: Bool) {
    let setupRes = _executeTransaction("../transactions/moet/setup_vault.cdc", [], signer)
    Test.expect(setupRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun setupYieldVault(_ signer: Test.TestAccount, beFailed: Bool) {
    let setupRes = _executeTransaction("../transactions/yield-token/setup_vault.cdc", [], signer)
    Test.expect(setupRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun mintMoet(signer: Test.TestAccount, to: Address, amount: UFix64, beFailed: Bool) {
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [to, amount], signer)
    Test.expect(mintRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun mintYield(signer: Test.TestAccount, to: Address, amount: UFix64, beFailed: Bool) {
    let mintRes = _executeTransaction("../transactions/yield-token/mint_yield.cdc", [to, amount], signer)
    Test.expect(mintRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun mintFlow(to: Test.TestAccount, amount: UFix64) {
    transferFlowTokens(to: to, amount: amount)
}

// Transfer Flow tokens from service account to recipient
access(all)
fun transferFlowTokens(to: Test.TestAccount, amount: UFix64) {
    let transferTx = Test.Transaction(
        code: Test.readFile("../transactions/flow-token/transfer_flow.cdc"),
        authorizers: [Test.serviceAccount().address],
        signers: [Test.serviceAccount()],
        arguments: [to.address, amount]
    )
    let res = Test.executeTransaction(transferTx)
    Test.expect(res, Test.beSucceeded())
}

access(all)
fun addStrategyComposer(signer: Test.TestAccount, strategyIdentifier: String, composerIdentifier: String, issuerStoragePath: StoragePath, beFailed: Bool) {
    let addRes = _executeTransaction("../transactions/tidal-yield/admin/add_strategy_composer.cdc",
            [ strategyIdentifier, composerIdentifier, issuerStoragePath ],
            signer
        )
    Test.expect(addRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun createTide(
    signer: Test.TestAccount,
    strategyIdentifier: String,
    vaultIdentifier: String,
    amount: UFix64,
    beFailed: Bool
) {
    let res = _executeTransaction("../transactions/tidal-yield/create_tide.cdc",
            [ strategyIdentifier, vaultIdentifier, amount ],
            signer
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun closeTide(signer: Test.TestAccount, id: UInt64, beFailed: Bool) {
    let res = _executeTransaction("../transactions/tidal-yield/close_tide.cdc", [id], signer)
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun rebalanceTide(signer: Test.TestAccount, id: UInt64, force: Bool, beFailed: Bool) {
    let res = _executeTransaction("../transactions/tidal-yield/admin/rebalance_auto_balancer_by_id.cdc", [id, force], signer)
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun getAutoBalancerIDByTideID(tideID: UInt64, beFailed: Bool): UInt64 {
    let res = _executeScript("../scripts/tidal-yield/get_auto_balancer_id_by_tide.cdc", [tideID])
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UInt64
}

access(all)
fun getAutoBalancerBalanceByID(id: UInt64, beFailed: Bool): UFix64 {
    let res = _executeScript("../scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc", [id])
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UFix64
}

/* --- Enhanced Logging Helpers --- */

// Logs complete position details in a readable format
access(all)
fun logPositionDetails(pid: UInt64, stage: String) {
    // Since we can't access TidalProtocol types here, we'll use a simpler approach
    let health = getPositionHealth(pid: pid, beFailed: false)
    log("")
    log("==================== POSITION DETAILS: ".concat(stage).concat(" ===================="))
    log("Position ID: ".concat(pid.toString()))
    log("Health Ratio: ".concat(health.toString()))
    log("=================================================================")
    log("")
}

// Logs AutoBalancer state with calculated value and explicit calculation details
access(all)
fun logAutoBalancerState(id: UInt64, yieldPrice: UFix64, stage: String) {
    let balance = getAutoBalancerBalanceByID(id: id, beFailed: false)
    
    log("")
    log("[AUTOBALANCER STATE] ".concat(stage))
    log("   AutoBalancer ID: ".concat(id.toString()))
    log("   YieldToken Balance: ".concat(balance.toString()))
    log("   YieldToken Price: ".concat(yieldPrice.toString()).concat(" MOET"))
    
    // Explicit value calculation
    let value = balance * yieldPrice
    log("   [CALCULATION] Total Value = Balance * Price")
    log("   [CALCULATION] ".concat(balance.toString()).concat(" * ").concat(yieldPrice.toString()).concat(" = ").concat(value.toString()))
    log("   Total Value in MOET: ".concat(value.toString()))
    log("")
}

// Logs price changes with clear formatting and error handling
access(all)
fun setMockOraclePriceWithLog(signer: Test.TestAccount, forTokenIdentifier: String, price: UFix64, tokenName: String) {
    log("")
    log("[PRICE UPDATE] Setting ".concat(tokenName).concat(" price"))
    log("   Token Identifier: ".concat(forTokenIdentifier))
    log("   New Price: ".concat(price.toString()).concat(" MOET"))
    log("   Previous Price: (not tracked - consider adding if needed)")
    
    // Execute the price update
    let setRes = _executeTransaction(
        "../transactions/mocks/oracle/set_price.cdc",
        [ forTokenIdentifier, price ],
        signer
    )
    
    if setRes.status != Test.ResultStatus.succeeded {
        log("   [ERROR] Price update FAILED!")
        if setRes.error != nil {
            log("   [ERROR] Message: ".concat(setRes.error!.message))
        }
    } else {
        log("   Price update successful")
    }
    log("")
}

// Logs transaction results with full error details
access(all)
fun logTransactionResult(result: Test.TransactionResult, operation: String) {
    log("")
    log("[TRANSACTION] ".concat(operation))
    log("   Status: ".concat(result.status == Test.ResultStatus.succeeded ? "SUCCEEDED" : "FAILED"))
    if result.error != nil {
        log("   ERROR MESSAGE: ".concat(result.error!.message))
        log("   ERROR TYPE: Transaction execution failed")
    }
    log("")
}

// Helper to log separator lines for clarity
access(all)
fun logSeparator(title: String) {
    log("")
    log("==================================================================")
    log("== ".concat(title))
    log("==================================================================")
    log("")
}

// Safe arithmetic helper that logs potential underflow/overflow
access(all)
fun safeSubtract(a: UFix64, b: UFix64, context: String): UFix64 {
    if a < b {
        log("[WARNING] Potential underflow in ".concat(context))
        log("   Attempting: ".concat(a.toString()).concat(" - ").concat(b.toString()))
        log("   Result would be negative, returning absolute difference")
        return b - a
    }
    return a - b
}

// Helper to log calculations explicitly
access(all)
fun logCalculation(description: String, formula: String, result: UFix64) {
    log("[CALCULATION] ".concat(description))
    log("   Formula: ".concat(formula))
    log("   Result: ".concat(result.toString()))
}

// Helper to validate and log division operations
access(all)
fun safeDivide(numerator: UFix64, denominator: UFix64, context: String): UFix64 {
    if denominator == 0.0 {
        log("[ERROR] Division by zero attempted in ".concat(context))
        log("   Numerator: ".concat(numerator.toString()))
        log("   Denominator: 0.0")
        panic("Division by zero error")
    }
    
    let result = numerator / denominator
    log("[SAFE DIVISION] ".concat(context))
    log("   ".concat(numerator.toString()).concat(" / ").concat(denominator.toString()).concat(" = ").concat(result.toString()))
    return result
}

/* --- Mock helpers --- */

access(all)
fun setMockOraclePrice(signer: Test.TestAccount, forTokenIdentifier: String, price: UFix64) {
    let setRes = _executeTransaction(
        "../transactions/mocks/oracle/set_price.cdc",
        [ forTokenIdentifier, price ],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun setMockSwapperLiquidityConnector(signer: Test.TestAccount, vaultStoragePath: StoragePath) {
    let setRes = _executeTransaction(
        "../transactions/mocks/swapper/set_liquidity_connector.cdc",
        [ vaultStoragePath ],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun getAvailableBalance(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool, beFailed: Bool): UFix64 {
    let res = _executeScript("../../lib/TidalProtocol/cadence/scripts/tidal-protocol/get_available_balance.cdc",
            [pid, vaultIdentifier, pullFromTopUpSource]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix64
}

access(all)
fun getPositionHealth(pid: UInt64, beFailed: Bool): UFix64 {
    let res = _executeScript("../../lib/TidalProtocol/cadence/scripts/tidal-protocol/position_health.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix64
}

access(all)
fun getPositionDetails(pid: UInt64, beFailed: Bool): TidalProtocol.PositionDetails {
    let res = _executeScript("../../lib/TidalProtocol/cadence/scripts/tidal-protocol/position_details.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! TidalProtocol.PositionDetails
}