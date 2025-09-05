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

access(all)
fun grantProtocolBeta(_ admin: Test.TestAccount, _ grantee: Test.TestAccount): Test.TransactionResult {
    let signers = admin.address == grantee.address ? [admin] : [admin, grantee]
    let betaTxn = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/tests/transactions/tidal-protocol/pool-management/03_grant_beta.cdc"),
        authorizers: [admin.address, grantee.address],
        signers: signers,
        arguments: []
    )
    return Test.executeTransaction(betaTxn)
}

access(all)
fun grantBeta(_ admin: Test.TestAccount, _ grantee: Test.TestAccount): Test.TransactionResult {
    let signers = admin.address == grantee.address ? [admin] : [admin, grantee]
    let betaTxn = Test.Transaction(
        code: Test.readFile("../transactions/tidal-yield/admin/grant_beta.cdc"),
        authorizers: [admin.address, grantee.address],
        signers: signers,
        arguments: []
    )
    return Test.executeTransaction(betaTxn)
}

/* --- Setup helpers --- */

// Common test setup function that deploys all required contracts
access(all) fun deployContracts() {
    // DeFiActions contracts
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../lib/DeFiActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../lib/DeFiActions/cadence/contracts/utils/DeFiActionsMathUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../lib/DeFiActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "SwapConnectors",
        path: "../../lib/DeFiActions/cadence/contracts/connectors/SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../lib/DeFiActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
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
        name: "TidalProtocolClosedBeta",
        path: "../../lib/TidalProtocol/cadence/contracts/TidalProtocolClosedBeta.cdc",
        arguments: []
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
        path: "../../lib/TidalProtocol/cadence/contracts/mocks/MockTidalProtocolConsumer.cdc",
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
        name: "TidalYieldClosedBeta",
        path: "../contracts/TidalYieldClosedBeta.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "TidalYield",
        path: "../contracts/TidalYield.cdc",
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

    setupBetaAccess()
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

access(all)
fun getAutoBalancerBalance(id: UInt64): UFix64? {
    let res = _executeScript("../scripts/tidal-yield/get_auto_balancer_balance_by_id.cdc", [id])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

access(all)
fun getAutoBalancerCurrentValue(id: UInt64): UFix64? {
    let res = _executeScript("../scripts/tidal-yield/get_auto_balancer_current_value_by_id.cdc", [id])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

access(all)
fun getPositionDetails(pid: UInt64, beFailed: Bool): TidalProtocol.PositionDetails {
    let res = _executeScript("../scripts/tidal-protocol/position_details.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())

    return res.returnValue as! TidalProtocol.PositionDetails
}

access(all)
fun getReserveBalanceForType(vaultIdentifier: String): UFix64 {
    let res = _executeScript(
        "../../lib/TidalProtocol/cadence/scripts/tidal-protocol/get_reserve_balance_for_type.cdc",
            [vaultIdentifier]
        )
    Test.expect(res, Test.beSucceeded())

    return res.returnValue as! UFix64
}

access(all)
fun positionAvailableBalance(
    pid: UInt64,
    type: String,
    pullFromSource: Bool,
    beFailed: Bool
): UFix64 {
    let res = _executeScript(
        "../scripts/tidal-protocol/get_available_balance.cdc",
            [pid, type, pullFromSource]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())

    return res.returnValue as! UFix64
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

// access(all)
// fun rebalancePosition(signer: Test.TestAccount, id: UInt64, force: Bool, beFailed: Bool) {
//     let res = _executeTransaction("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/rebalance_auto_balancer_by_id.cdc", [id, force], signer)
//     Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
// }

/* --- Event helpers --- */

access(all)
fun getLastPositionOpenedEvent(_ evts: [AnyStruct]): AnyStruct { // can't return event types directly, they must be cast by caller
    Test.assert(evts.length > 0, message: "Expected at least 1 TidalProtocol.Opened event but found none")
    return evts[evts.length - 1] as! TidalProtocol.Opened
}

access(all)
fun getLastPositionDepositedEvent(_ evts: [AnyStruct]): AnyStruct { // can't return event types directly, they must be cast by caller
    Test.assert(evts.length > 0, message: "Expected at least 1 TidalProtocol.Deposited event but found none")
    return evts[evts.length - 1] as! TidalProtocol.Deposited
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
fun equalAmounts(a: UFix64, b: UFix64, tolerance: UFix64): Bool {
    if a > b {
        return a - b <= tolerance
    }
    return b - a <= tolerance
}

/* --- Formatting helpers --- */

access(all) fun formatValue(_ value: UFix64): String {
    // Format to 11 digits with padding
    let str = value.toString()
    let parts = str.split(separator: ".")
    if parts.length == 1 {
        return str.concat(".00000000")
    }
    let decimals = parts[1]
    let padding = 8 - decimals.length
    var padded = decimals
    var i = 0
    while i < padding {
        padded = padded.concat("0")
        i = i + 1
    }
    return parts[0].concat(".").concat(padded)
}

access(all) fun formatDrift(_ drift: UFix64): String {
    // Handle negative drift by checking if we're dealing with a wrapped negative
    // In Cadence, UFix64 can't be negative, so we need to handle this differently
    return formatValue(drift)
}

access(all) fun formatPercent(_ percent: UFix64): String {
    // Format to 8 decimal places
    let scaled = percent * 100.0
    return scaled.toString()
}

/* --- Const Helpers --- */
access(all) let TOLERANCE = 0.00000001

access(all) fun setupBetaAccess(): Void {
    let protocolAccount = Test.getAccount(0x0000000000000008)
    let tidalYieldAccount = Test.getAccount(0x0000000000000009)
    let protocolBeta = grantProtocolBeta(protocolAccount, protocolAccount)
    Test.expect(protocolBeta, Test.beSucceeded())

    let tidalYieldBeta = grantProtocolBeta(protocolAccount, tidalYieldAccount)
    Test.expect(tidalYieldBeta, Test.beSucceeded())
}
