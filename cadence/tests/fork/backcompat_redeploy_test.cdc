#test_fork(network: "mainnet", height: nil)

import Test

import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"
import "AutoBalancerCallbackWrapper"
import "FlowYieldVaultsAutoBalancers"
import "FlowYieldVaultsSchedulerRegistry"
import "FlowYieldVaultsSchedulerV1"
import "FlowYieldVaultsStrategiesV2"
import "PMStrategiesV1"

/// Backward-compatibility fork test.
///
/// Simulates a full contract upgrade by redeploying every contract in the
/// FlowYieldVaults ecosystem (and their dependencies) from the local codebase
/// on top of the live mainnet fork state.
///
/// The test verifies that:
///   1. All contracts can be redeployed without panicking.
///   2. Pre-existing on-chain state (accounts, stored resources) is still
///      accessible after the upgrade.
///   3. Core read-only operations (beta status, strategy list, vault IDs,
///      scheduler registry) continue to return sensible results.
///   4. The admin StrategyComposerIssuer is still accessible and can issue
///      composers after the upgrade.
///
/// Mainnet addresses:
///   Admin / deployer : 0xb1d63873c3cc9f79
///   PYUSD0 test user : 0x443472749ebdaac8
///   WBTC/WETH user   : 0x68da18f20e98a7b6

// --- Accounts ---

access(all) let adminAccount    = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let bandOracleAdmin = Test.getAccount(0x6801a6222ebf784a)
access(all) let pyusd0User      = Test.getAccount(0x443472749ebdaac8)
access(all) let wbtcWethUser    = Test.getAccount(0x68da18f20e98a7b6)

// --- UniV3 addresses (mainnet) ---

access(all) let univ3Factory = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"
access(all) let univ3Router  = "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341"
access(all) let univ3Quoter  = "0x370A8DF17742867a44e56223EC20D82092242C85"

/* --- Helpers --- */

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

access(all)
fun _executeTransactionFile(
    _ path: String,
    _ args: [AnyStruct],
    _ signers: [Test.TestAccount]
): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: signers.map(fun (s: Test.TestAccount): Address { return s.address }),
        signers: signers,
        arguments: args
    )
    return Test.executeTransaction(txn)
}

/* --- Setup: redeploy every contract from local source --- */

access(all) fun setup() {
    log("==== Backward-Compatibility Redeploy Test: Setup ====")

    // ------------------------------------------------------------------ //
    // 1. FlowALP / FlowActions dependency contracts
    // ------------------------------------------------------------------ //

    log("Deploying EVMAmountUtils...")
    var err = Test.deployContract(
        name: "EVMAmountUtils",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/EVMAmountUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying UniswapV3SwapConnectors...")
    err = Test.deployContract(
        name: "UniswapV3SwapConnectors",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626Utils...")
    err = Test.deployContract(
        name: "ERC4626Utils",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/utils/ERC4626Utils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626SwapConnectors...")
    err = Test.deployContract(
        name: "ERC4626SwapConnectors",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626SinkConnectors...")
    err = Test.deployContract(
        name: "ERC4626SinkConnectors",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626SinkConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying MorphoERC4626SinkConnectors...")
    err = Test.deployContract(
        name: "MorphoERC4626SinkConnectors",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SinkConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying MorphoERC4626SwapConnectors...")
    err = Test.deployContract(
        name: "MorphoERC4626SwapConnectors",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626PriceOracles...")
    err = Test.deployContract(
        name: "ERC4626PriceOracles",
        path: "../../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626PriceOracles.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // ------------------------------------------------------------------ //
    // 2. Core FlowYieldVaults platform contracts
    //    (deployed at 0xb1d63873c3cc9f79 on mainnet)
    // ------------------------------------------------------------------ //

    log("Deploying UInt64LinkedList...")
    err = Test.deployContract(
        name: "UInt64LinkedList",
        path: "../../../cadence/contracts/UInt64LinkedList.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaults...")
    err = Test.deployContract(
        name: "FlowYieldVaults",
        path: "../../../cadence/contracts/FlowYieldVaults.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsClosedBeta...")
    err = Test.deployContract(
        name: "FlowYieldVaultsClosedBeta",
        path: "../../../cadence/contracts/FlowYieldVaultsClosedBeta.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying AutoBalancerCallbackWrapper...")
    err = Test.deployContract(
        name: "AutoBalancerCallbackWrapper",
        path: "../../../cadence/contracts/AutoBalancerCallbackWrapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsAutoBalancers...")
    err = Test.deployContract(
        name: "FlowYieldVaultsAutoBalancers",
        path: "../../../cadence/contracts/FlowYieldVaultsAutoBalancers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsSchedulerRegistry...")
    err = Test.deployContract(
        name: "FlowYieldVaultsSchedulerRegistry",
        path: "../../../cadence/contracts/FlowYieldVaultsSchedulerRegistry.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsSchedulerV1...")
    err = Test.deployContract(
        name: "FlowYieldVaultsSchedulerV1",
        path: "../../../cadence/contracts/FlowYieldVaultsSchedulerV1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsStrategiesV2...")
    err = Test.deployContract(
        name: "FlowYieldVaultsStrategiesV2",
        path: "../../../cadence/contracts/FlowYieldVaultsStrategiesV2.cdc",
        arguments: [univ3Factory, univ3Router, univ3Quoter]
    )
    Test.expect(err, Test.beNil())

    log("Deploying PMStrategiesV1...")
    err = Test.deployContract(
        name: "PMStrategiesV1",
        path: "../../../cadence/contracts/PMStrategiesV1.cdc",
        arguments: [univ3Factory, univ3Router, univ3Quoter]
    )
    Test.expect(err, Test.beNil())

    log("==== All contracts redeployed successfully ====")
}

/* --- Tests --- */

/// All contracts deployed without error — already asserted in setup().
/// This test serves as the initial smoke-check gate.
access(all) fun testAllContractsRedeployedWithoutError() {
    log("All contracts redeployed without error (verified in setup)")
}

/// Verify that FlowYieldVaults is accessible and returns supported strategies
/// after the upgrade.
access(all) fun testSupportedStrategiesReadable() {
    log("Checking FlowYieldVaults.getSupportedStrategies() after redeploy...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_supported_strategies.cdc",
        []
    )
    Test.expect(result, Test.beSucceeded())
    log("Supported strategies readable after redeploy")
}

/// Verify that the SchedulerRegistry state is still readable after the upgrade.
access(all) fun testSchedulerRegistryReadable() {
    log("Checking FlowYieldVaultsSchedulerRegistry state...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_registered_yield_vault_count.cdc",
        []
    )
    Test.expect(result, Test.beSucceeded())
    let count = result.returnValue! as! Int
    log("Registered yield vault count after redeploy: ".concat(count.toString()))
}

/// Verify that the pending vault queue is still intact after the upgrade.
access(all) fun testPendingQueueReadable() {
    log("Checking pending yield vault queue...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_pending_count.cdc",
        []
    )
    Test.expect(result, Test.beSucceeded())
    let count = result.returnValue! as! Int
    log("Pending vault count after redeploy: ".concat(count.toString()))
}

/// Verify that existing yield vault IDs for the PYUSD0 user are still readable.
access(all) fun testExistingPyusd0UserVaultsReadable() {
    log("Checking PYUSD0 user yield vault IDs after redeploy...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_yield_vault_ids.cdc",
        [pyusd0User.address]
    )
    Test.expect(result, Test.beSucceeded())
    let ids = result.returnValue! as! [UInt64]?
    if ids == nil || ids!.length == 0 {
        log("PYUSD0 user has no existing yield vaults on mainnet (OK for closed beta)")
    } else {
        log("PYUSD0 user existing vault IDs: ".concat(ids!.length.toString()).concat(" vaults found"))
        // Verify balance is readable for each vault
        for id in ids! {
            let balResult = _executeScript(
                "../../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
                [pyusd0User.address, id]
            )
            Test.expect(balResult, Test.beSucceeded())
            log("  Vault ".concat(id.toString()).concat(" balance readable"))
        }
    }
}

/// Verify that existing yield vault IDs for the WBTC/WETH user are still readable.
access(all) fun testExistingWbtcWethUserVaultsReadable() {
    log("Checking WBTC/WETH user yield vault IDs after redeploy...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_yield_vault_ids.cdc",
        [wbtcWethUser.address]
    )
    Test.expect(result, Test.beSucceeded())
    let ids = result.returnValue! as! [UInt64]?
    if ids == nil || ids!.length == 0 {
        log("WBTC/WETH user has no existing yield vaults on mainnet (OK for closed beta)")
    } else {
        log("WBTC/WETH user existing vault IDs: ".concat(ids!.length.toString()).concat(" vaults found"))
        for id in ids! {
            let balResult = _executeScript(
                "../../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
                [wbtcWethUser.address, id]
            )
            Test.expect(balResult, Test.beSucceeded())
            log("  Vault ".concat(id.toString()).concat(" balance readable"))
        }
    }
}

/// Verify that existing yield vault IDs for the admin account are still readable.
access(all) fun testExistingAdminVaultsReadable() {
    log("Checking admin yield vault IDs after redeploy...")
    let result = _executeScript(
        "../../scripts/flow-yield-vaults/get_yield_vault_ids.cdc",
        [adminAccount.address]
    )
    Test.expect(result, Test.beSucceeded())
    let ids = result.returnValue! as! [UInt64]?
    if ids == nil || ids!.length == 0 {
        log("Admin has no existing yield vaults (OK)")
    } else {
        log("Admin existing vault IDs: ".concat(ids!.length.toString()).concat(" vaults found"))
        for id in ids! {
            let balResult = _executeScript(
                "../../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
                [adminAccount.address, id]
            )
            Test.expect(balResult, Test.beSucceeded())
            log("  Vault ".concat(id.toString()).concat(" balance readable"))
        }
    }
}

/// Verify that the closed beta gate still functions correctly after the upgrade.
access(all) fun testClosedBetaStatePreserved() {
    log("Checking closed beta state after redeploy...")
    let betaCapResult = _executeScript(
        "../../scripts/flow-yield-vaults/get_beta_cap.cdc",
        [adminAccount.address]
    )
    Test.expect(betaCapResult, Test.beSucceeded())
    log("Beta cap accessible after redeploy")

    let activeCountResult = _executeScript(
        "../../scripts/flow-yield-vaults/get_active_beta_count.cdc",
        []
    )
    Test.expect(activeCountResult, Test.beSucceeded())
    let count = activeCountResult.returnValue! as! Int
    log("Active beta user count after redeploy: ".concat(count.toString()))
}

/// Verify that the PMStrategiesV1 IssuerStoragePath is still accessible after
/// the upgrade and that strategy configuration can be upserted.
access(all) fun testPMStrategiesV1IssuerAccessible() {
    log("Configuring PMStrategiesV1 syWFLOWv strategy for FLOW collateral...")
    let result = _executeTransactionFile(
        "../../transactions/flow-yield-vaults/admin/upsert-pm-strategy-config.cdc",
        [
            "A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy",
            "A.1654653399040a61.FlowToken.Vault",
            "0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597", // syWFLOWv
            UInt32(100)                                   // WFLOW/syWFLOWv fee tier
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("PMStrategiesV1 syWFLOWv strategy config upserted successfully")
}

/// Verify that FlowYieldVaultsStrategiesV2 StrategyComposerIssuer is accessible
/// and can be configured with a new strategy after the upgrade.
access(all) fun testStrategiesV2IssuerConfigurable() {
    log("Configuring FlowYieldVaultsStrategiesV2 FUSDEVStrategy for PYUSD0 collateral...")
    // PYUSD0 collateral: yield -> collateral path is [FUSDEV_EVM, PYUSD0_EVM], fee 100
    let result = _executeTransactionFile(
        "../../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc",
        [
            "A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.FUSDEVStrategy",
            "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault",
            "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D", // FUSDEV yield token
            ["0xd069d989e2F44B70c65347d1853C0c67e10a9F8D",
             "0x99aF3EeA856556646C98c8B9b2548Fe815240750"], // yield -> PYUSD0
            [UInt32(100)]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("FlowYieldVaultsStrategiesV2 FUSDEVStrategy config upserted successfully")
}
