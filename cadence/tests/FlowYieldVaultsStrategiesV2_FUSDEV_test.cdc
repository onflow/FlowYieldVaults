#test_fork(network: "mainnet", height: nil)

import Test

import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"

/// Fork test for FlowYieldVaultsStrategiesV2 FUSDEVStrategy.
///
/// Tests the full YieldVault lifecycle (create, deposit, withdraw, close) for each supported
/// collateral type: WFLOW (FlowToken), WBTC, and WETH.
///
/// PYUSD0 cannot be used as collateral — it is the FUSDEV vault's underlying asset. The
/// test setup intentionally omits a PYUSD0 collateral config so that negative tests can
/// assert the correct rejection.
///
/// Strategy:
///   <collateral> → FlowALP borrow MOET → swap MOET→PYUSD0 → ERC4626 deposit → FUSDEV (Morpho vault)
///   Close: FUSDEV → PYUSD0 (redeem) → MOET → repay FlowALP → <collateral> returned to user
///
/// Mainnet addresses:
///   - Admin (FlowYieldVaults deployer): 0xb1d63873c3cc9f79
///   - WFLOW/PYUSD0 negative-test user: 0x443472749ebdaac8 (holds PYUSD0 and FLOW on mainnet)
///   - WBTC/WETH user: 0x68da18f20e98a7b6 (has ~12 WETH in EVM COA; WETH bridged + WBTC swapped in setup)
///   - UniV3 Factory: 0xca6d7Bb03334bBf135902e1d919a5feccb461632
///   - UniV3 Router:  0xeEDC6Ff75e1b10B903D9013c358e446a73d35341
///   - UniV3 Quoter:  0x370A8DF17742867a44e56223EC20D82092242C85
///   - FUSDEV (Morpho ERC4626): 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D
///   - PYUSD0:  0x99aF3EeA856556646C98c8B9b2548Fe815240750
///   - WFLOW:   0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e
///   - WBTC:    0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579 (cbBTC; no WFLOW pool — use WETH as intermediate)
///   - WETH:    0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590

// --- Accounts ---

/// Mainnet admin account — deployer of FlowYieldVaults, FlowYieldVaultsClosedBeta, FlowYieldVaultsStrategiesV2
access(all) let adminAccount = Test.getAccount(0xb1d63873c3cc9f79)

/// WFLOW test user — holds FLOW (and PYUSD0) on mainnet.
/// Used for WFLOW lifecycle tests and for the negative PYUSD0 collateral test.
access(all) let flowUser = Test.getAccount(0x443472749ebdaac8)

/// FlowToken contract account — used to provision FLOW to flowUser in setup.
access(all) let flowTokenAccount = Test.getAccount(0x1654653399040a61)

/// WBTC/WETH holder — this account has ~12 WETH in its EVM COA on mainnet.
/// WETH is bridged to Cadence during setup(), and some WETH is then swapped → WBTC
/// via the UniV3 WETH/WBTC pool so that both collateral types can be tested.
/// COA EVM: 0x000000000000000000000002b87c966bc00bc2c4
access(all) let wbtcUser = Test.getAccount(0x68da18f20e98a7b6)
access(all) let wethUser = Test.getAccount(0x68da18f20e98a7b6)

// --- Strategy Config ---

access(all) let fusdEvStrategyIdentifier = "A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.FUSDEVStrategy"
access(all) let composerIdentifier       = "A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MorphoERC4626StrategyComposer"
access(all) let issuerStoragePath: StoragePath = /storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xb1d63873c3cc9f79

// --- Cadence Vault Type Identifiers ---

/// FlowToken (WFLOW on EVM side) — used as WFLOW collateral
access(all) let flowVaultIdentifier  = "A.1654653399040a61.FlowToken.Vault"
/// VM-bridged ERC-20 tokens
access(all) let wbtcVaultIdentifier  = "A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault"
access(all) let wethVaultIdentifier  = "A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault"
access(all) let pyusd0VaultIdentifier = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"

// --- EVM Addresses ---

access(all) let fusdEvEVMAddress   = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
access(all) let pyusd0EVMAddress   = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let wflowEVMAddress    = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
access(all) let wbtcEVMAddress     = "0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579"
access(all) let wethEVMAddress     = "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"

// --- Test State (vault IDs set during create tests, read by subsequent tests) ---

access(all) var flowVaultID: UInt64  = 0
access(all) var wbtcVaultID: UInt64  = 0
access(all) var wethVaultID: UInt64  = 0

/* --- Helpers --- */

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

access(all)
fun _executeTransactionFile(_ path: String, _ args: [AnyStruct], _ signers: [Test.TestAccount]): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: signers.map(fun (s: Test.TestAccount): Address { return s.address }),
        signers: signers,
        arguments: args
    )
    return Test.executeTransaction(txn)
}

access(all)
fun equalAmounts(a: UFix64, b: UFix64, tolerance: UFix64): Bool {
    if a > b { return a - b <= tolerance }
    return b - a <= tolerance
}

/// Returns the most-recently-created YieldVault ID for the given account.
access(all)
fun _latestVaultID(_ user: Test.TestAccount): UInt64 {
    let r = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_ids.cdc", [user.address])
    Test.expect(r, Test.beSucceeded())
    let ids = r.returnValue! as! [UInt64]?
    Test.assert(ids != nil && ids!.length > 0, message: "Expected at least one yield vault for ".concat(user.address.toString()))
    return ids![ids!.length - 1]
}

/* --- Setup --- */

access(all) fun setup() {
    log("==== FlowYieldVaultsStrategiesV2 FUSDEV Fork Test Setup ====")

    log("Deploying EVMAmountUtils...")
    var err = Test.deployContract(
        name: "EVMAmountUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/EVMAmountUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying UniswapV3SwapConnectors...")
    err = Test.deployContract(
        name: "UniswapV3SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626Utils...")
    err = Test.deployContract(
        name: "ERC4626Utils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/ERC4626Utils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626SwapConnectors...")
    err = Test.deployContract(
        name: "ERC4626SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // MorphoERC4626SinkConnectors must come before MorphoERC4626SwapConnectors (it imports it).
    log("Deploying MorphoERC4626SinkConnectors...")
    err = Test.deployContract(
        name: "MorphoERC4626SinkConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SinkConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying MorphoERC4626SwapConnectors...")
    err = Test.deployContract(
        name: "MorphoERC4626SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaults...")
    err = Test.deployContract(
        name: "FlowYieldVaults",
        path: "../../cadence/contracts/FlowYieldVaults.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying ERC4626PriceOracles...")
    err = Test.deployContract(
        name: "ERC4626PriceOracles",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626PriceOracles.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowALPv0...")
    err = Test.deployContract(
        name: "FlowALPv0",
        path: "../../lib/FlowALP/cadence/contracts/FlowALPv0.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsAutoBalancers...")
    err = Test.deployContract(
        name: "AutoBalancers",
        path: "../../cadence/contracts/AutoBalancers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsAutoBalancers...")
    err = Test.deployContract(
        name: "FlowYieldVaultsAutoBalancers",
        path: "../../cadence/contracts/FlowYieldVaultsAutoBalancers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // temporary commented until merged with syWFLOW strategy
    // log("Deploying FlowYieldVaultsStrategiesV2...")
    // err = Test.deployContract(
    //     name: "FlowYieldVaultsStrategiesV2",
    //     path: "../../cadence/contracts/FlowYieldVaultsStrategiesV2.cdc",
    //     arguments: [
    //         "0xca6d7Bb03334bBf135902e1d919a5feccb461632",
    //         "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341",
    //         "0x370A8DF17742867a44e56223EC20D82092242C85"
    //     ]
    // )
    // Test.expect(err, Test.beNil())

    // Configure UniV3 paths for FUSDEVStrategy.
    // Closing direction: FUSDEV → PYUSD0 (Morpho redeem, fee 100) → <collateral> (UniV3 swap, fee 3000).
    // PYUSD0 is intentionally NOT configured as collateral — it is the underlying asset.

    log("Configuring FUSDEVStrategy + WFLOW (FUSDEV→PYUSD0→WFLOW fees 100/3000)...")
    var result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc",
        [
            fusdEvStrategyIdentifier,
            flowVaultIdentifier,
            fusdEvEVMAddress,
            [fusdEvEVMAddress, pyusd0EVMAddress, wflowEVMAddress],
            [100 as UInt32, 3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // No WFLOW/WBTC pool on Flow EVM — PYUSD0 is the intermediate for both legs.
    log("Configuring FUSDEVStrategy + WBTC (FUSDEV→PYUSD0→WBTC fees 100/3000)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc",
        [
            fusdEvStrategyIdentifier,
            wbtcVaultIdentifier,
            fusdEvEVMAddress,
            [fusdEvEVMAddress, pyusd0EVMAddress, wbtcEVMAddress],
            [100 as UInt32, 3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    log("Configuring FUSDEVStrategy + WETH (FUSDEV→PYUSD0→WETH fees 100/3000)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc",
        [
            fusdEvStrategyIdentifier,
            wethVaultIdentifier,
            fusdEvEVMAddress,
            [fusdEvEVMAddress, pyusd0EVMAddress, wethEVMAddress],
            [100 as UInt32, 3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Register FUSDEVStrategy in the FlowYieldVaults StrategyFactory
    log("Registering FUSDEVStrategy in FlowYieldVaults factory...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/add_strategy_composer.cdc",
        [fusdEvStrategyIdentifier, composerIdentifier, issuerStoragePath],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Grant beta access to all user accounts
    log("Granting beta access to WFLOW/PYUSD0 user...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, flowUser]
    )
    Test.expect(result, Test.beSucceeded())

    log("Granting beta access to WBTC/WETH user (0x68da18f20e98a7b6)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    // Provision extra FLOW to flowUser so that testDepositToFUSDEVYieldVault_WFLOW has enough balance.
    // flowUser starts with ~11 FLOW; the create uses 10.0, leaving ~1 FLOW — not enough for a 5.0 deposit.
    log("Provisioning 20.0 FLOW to WFLOW user from FlowToken contract account...")
    result = _executeTransactionFile(
        "../transactions/flow-token/transfer_flow.cdc",
        [flowUser.address, 20.0],
        [flowTokenAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Provision WETH and WBTC for the WBTC/WETH user.
    // The COA at 0x000000000000000000000002b87c966bc00bc2c4 holds ~12 WETH on mainnet.
    log("Bridging 2 WETH from COA to Cadence and swapping 0.1 WETH → WBTC for WBTC/WETH user...")

    // Bridge 2 WETH (2_000_000_000_000_000_000 at 18 decimals) from COA to Cadence.
    let bridgeResult = _executeTransactionFile(
        "../../lib/FlowALP/FlowActions/cadence/tests/transactions/bridge/bridge_tokens_from_evm.cdc",
        [wethVaultIdentifier, 2000000000000000000 as UInt256],
        [wbtcUser]
    )
    Test.expect(bridgeResult, Test.beSucceeded())

    // Swap 0.1 WETH → WBTC via UniV3 WETH/WBTC pool (fee 3000).
    let swapResult = _executeTransactionFile(
        "transactions/provision_wbtc_from_weth.cdc",
        [
            "0xca6d7Bb03334bBf135902e1d919a5feccb461632",  // UniV3 factory
            "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341",  // UniV3 router
            "0x370A8DF17742867a44e56223EC20D82092242C85",  // UniV3 quoter
            wethEVMAddress,
            wbtcEVMAddress,
            3000 as UInt32,
            0.1 as UFix64
        ],
        [wbtcUser]
    )
    Test.expect(swapResult, Test.beSucceeded())

    log("==== Setup Complete ====")
}

/* =========================================================
   WFLOW (FlowToken) collateral lifecycle
   ========================================================= */

access(all) fun testCreateFUSDEVYieldVault_WFLOW() {
    log("Creating FUSDEVStrategy yield vault with 10.0 FLOW...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, flowVaultIdentifier, 10.0],
        [flowUser]
    )
    Test.expect(result, Test.beSucceeded())

    flowVaultID = _latestVaultID(flowUser)
    log("Created WFLOW vault ID: ".concat(flowVaultID.toString()))

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(balance != nil && balance! > 0.0, message: "Expected positive balance after create (WFLOW)")
    log("WFLOW vault balance after create: ".concat(balance!.toString()))
}

access(all) fun testDepositToFUSDEVYieldVault_WFLOW() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 5.0
    log("Depositing 5.0 FLOW to vault ".concat(flowVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [flowVaultID, depositAmount], [flowUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: 0.1),
        message: "WFLOW deposit: expected ~".concat((before + depositAmount).toString()).concat(", got ").concat(after.toString()))
    log("WFLOW vault balance after deposit: ".concat(after.toString()))
}

access(all) fun testWithdrawFromFUSDEVYieldVault_WFLOW() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 3.0
    log("Withdrawing 3.0 FLOW from vault ".concat(flowVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [flowVaultID, withdrawAmount], [flowUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: 0.1),
        message: "WFLOW withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WFLOW vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WFLOW() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?) ?? 0.0
    log("Closing WFLOW vault ".concat(flowVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [flowVaultID], [flowUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WFLOW vault should no longer exist after close")
    log("WFLOW yield vault closed successfully")
}

/* =========================================================
   WBTC collateral lifecycle
   ========================================================= */

access(all) fun testCreateFUSDEVYieldVault_WBTC() {
    log("Creating FUSDEVStrategy yield vault with 0.0001 WBTC...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, wbtcVaultIdentifier, 0.0001],
        [wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    wbtcVaultID = _latestVaultID(wbtcUser)
    log("Created WBTC vault ID: ".concat(wbtcVaultID.toString()))

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(balance != nil && balance! > 0.0, message: "Expected positive balance after create (WBTC)")
    log("WBTC vault balance after create: ".concat(balance!.toString()))
}

access(all) fun testDepositToFUSDEVYieldVault_WBTC() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 0.00005
    log("Depositing 0.00005 WBTC to vault ".concat(wbtcVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [wbtcVaultID, depositAmount], [wbtcUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: 0.000005),
        message: "WBTC deposit: expected ~".concat((before + depositAmount).toString()).concat(", got ").concat(after.toString()))
    log("WBTC vault balance after deposit: ".concat(after.toString()))
}

access(all) fun testWithdrawFromFUSDEVYieldVault_WBTC() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 0.00003
    log("Withdrawing 0.00003 WBTC from vault ".concat(wbtcVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [wbtcVaultID, withdrawAmount], [wbtcUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: 0.000005),
        message: "WBTC withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WBTC vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WBTC() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    log("Closing WBTC vault ".concat(wbtcVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wbtcVaultID], [wbtcUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WBTC vault should no longer exist after close")
    log("WBTC yield vault closed successfully")
}

/* =========================================================
   WETH collateral lifecycle
   ========================================================= */

access(all) fun testCreateFUSDEVYieldVault_WETH() {
    log("Creating FUSDEVStrategy yield vault with 0.001 WETH...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, wethVaultIdentifier, 0.001],
        [wethUser]
    )
    Test.expect(result, Test.beSucceeded())

    wethVaultID = _latestVaultID(wethUser)
    log("Created WETH vault ID: ".concat(wethVaultID.toString()))

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(balance != nil && balance! > 0.0, message: "Expected positive balance after create (WETH)")
    log("WETH vault balance after create: ".concat(balance!.toString()))
}

access(all) fun testDepositToFUSDEVYieldVault_WETH() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 0.0005
    log("Depositing 0.0005 WETH to vault ".concat(wethVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [wethVaultID, depositAmount], [wethUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: 0.00005),
        message: "WETH deposit: expected ~".concat((before + depositAmount).toString()).concat(", got ").concat(after.toString()))
    log("WETH vault balance after deposit: ".concat(after.toString()))
}

access(all) fun testWithdrawFromFUSDEVYieldVault_WETH() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 0.0003
    log("Withdrawing 0.0003 WETH from vault ".concat(wethVaultID.toString()).concat("..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [wethVaultID, withdrawAmount], [wethUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: 0.00005),
        message: "WETH withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WETH vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WETH() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    log("Closing WETH vault ".concat(wethVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wethVaultID], [wethUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WETH vault should no longer exist after close")
    log("WETH yield vault closed successfully")
}

/* =========================================================
   Negative tests
   ========================================================= */

/// PYUSD0 is the underlying asset of FUSDEV — the strategy composer has no collateral config for
/// it, so attempting to create a vault with PYUSD0 as collateral must be rejected.
access(all) fun testCannotCreateYieldVaultWithPYUSD0AsCollateral() {
    log("Attempting to create FUSDEVStrategy vault with PYUSD0 (underlying asset) as collateral — expecting failure...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, pyusd0VaultIdentifier, 1.0],
        [flowUser]
    )
    Test.expect(result, Test.beFailed())
    log("Correctly rejected PYUSD0 as collateral")
}

/// Depositing the wrong token type into an existing YieldVault must be rejected.
/// Here wethUser owns both WETH and WBTC (set up in setup()).
/// We create a fresh WETH vault, then attempt to deposit WBTC into it — the strategy
/// pre-condition should panic on the type mismatch.
access(all) fun testCannotDepositWrongTokenToYieldVault() {
    log("Creating a fresh WETH vault for wrong-token deposit test...")
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, wethVaultIdentifier, 0.001],
        [wethUser]
    )
    Test.expect(createResult, Test.beSucceeded())
    let freshWethVaultID = _latestVaultID(wethUser)
    log("Created WETH vault ID: ".concat(freshWethVaultID.toString()).concat(" — now attempting to deposit WBTC into it..."))

    // Attempt to deposit WBTC (wrong type) into the WETH vault — must fail
    let depositResult = _executeTransactionFile(
        "transactions/deposit_wrong_token.cdc",
        [freshWethVaultID, wbtcVaultIdentifier, 0.00001],
        [wethUser]
    )
    Test.expect(depositResult, Test.beFailed())
    log("Correctly rejected wrong-token deposit (WBTC into WETH vault)")
}
