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
///   <collateral> → FlowALP borrow PYUSD0 → ERC4626 deposit → FUSDEV (Morpho vault)
///   Close: FUSDEV → PYUSD0 (ERC4626 redeem) → repay FlowALP → <collateral> returned to user
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

/// Large PYUSD0 holder (~70k PYUSD0) — used solely to seed the FlowALP pool's
/// PYUSD0 reserves so the pool can service PYUSD0 drawdowns for FUSDEVStrategy positions.
access(all) let pyusd0Holder = Test.getAccount(0x24263c125b7770e0)

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

/// Relative tolerance used in all balance assertions (1%).
access(all) let tolerancePct: UFix64 = 0.01

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

/// Returns the FUSDEV share balance held in the AutoBalancer for the given vault ID,
/// or nil if no AutoBalancer exists.
access(all)
fun _autoBalancerBalance(_ vaultID: UInt64): UFix64? {
    let r = _executeScript("../scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc", [vaultID])
    Test.expect(r, Test.beSucceeded())
    return r.returnValue as? UFix64
}

/// Returns the WETH Cadence vault balance for the given account.
access(all)
fun _wethBalance(_ user: Test.TestAccount): UFix64 {
    let r = _executeScript("../scripts/tokens/get_vault_balance_by_type.cdc", [user.address, wethVaultIdentifier])
    Test.expect(r, Test.beSucceeded())
    return (r.returnValue as? UFix64) ?? 0.0
}

/// Returns the native FLOW balance for the given account.
access(all)
fun _flowBalance(_ user: Test.TestAccount): UFix64 {
    let r = _executeScript("../scripts/flow-yield-vaults/get_flow_balance.cdc", [user.address])
    Test.expect(r, Test.beSucceeded())
    return (r.returnValue as? UFix64) ?? 0.0
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

    log("Deploying UInt64LinkedList...")
    err = Test.deployContract(
        name: "UInt64LinkedList",
        path: "../../cadence/contracts/UInt64LinkedList.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying AutoBalancers...")
    err = Test.deployContract(
        name: "AutoBalancers",
        path: "../../cadence/contracts/AutoBalancers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsSchedulerRegistryV1...")
    err = Test.deployContract(
        name: "FlowYieldVaultsSchedulerRegistryV1",
        path: "../../cadence/contracts/FlowYieldVaultsSchedulerRegistryV1.cdc",
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

    log("Deploying FlowYieldVaultsAutoBalancersV1...")
    err = Test.deployContract(
        name: "FlowYieldVaultsAutoBalancersV1",
        path: "../../cadence/contracts/FlowYieldVaultsAutoBalancersV1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaultsStrategiesV2...")
    err = Test.deployContract(
        name: "FlowYieldVaultsStrategiesV2",
        path: "../../cadence/contracts/FlowYieldVaultsStrategiesV2.cdc",
        arguments: [
            "0xca6d7Bb03334bBf135902e1d919a5feccb461632",
            "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341",
            "0x370A8DF17742867a44e56223EC20D82092242C85"
        ]
    )
    Test.expect(err, Test.beNil())

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

    // Seed the FlowALP pool with PYUSD0 reserves.
    // FUSDEVStrategy borrows PYUSD0 as its debt token (drawDownSink expects PYUSD0).
    // The pool can mint MOET but must draw non-MOET tokens from reserves[tokenType].
    // pyusd0Holder (0x24263c125b7770e0) holds ~70k PYUSD0 on mainnet — grant pool
    // access and have them deposit 1000 PYUSD0 so the pool can service drawdowns.
    let alpAdmin = Test.getAccount(0x6b00ff876c299c61)
    log("Granting pyusd0Holder FlowALP pool cap for PYUSD0 reserve position...")
    result = _executeTransactionFile(
        "../../lib/FlowALP/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc",
        [],
        [alpAdmin, pyusd0Holder]
    )
    Test.expect(result, Test.beSucceeded())

    log("Creating 1000 PYUSD0 reserve position in FlowALP pool (pushToDrawDownSink: false)...")
    result = _executeTransactionFile(
        "../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
        [1000.0 as UFix64, /storage/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault as StoragePath, false as Bool],
        [pyusd0Holder]
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
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
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
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "WFLOW withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WFLOW vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WFLOW() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID]).returnValue! as! UFix64?) ?? 0.0
    let collateralBefore = (_executeScript("../scripts/flow-yield-vaults/get_flow_balance.cdc", [flowUser.address]).returnValue! as! UFix64)
    log("Closing WFLOW vault ".concat(flowVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [flowVaultID], [flowUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [flowUser.address, flowVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WFLOW vault should no longer exist after close")
    let collateralAfter = (_executeScript("../scripts/flow-yield-vaults/get_flow_balance.cdc", [flowUser.address]).returnValue! as! UFix64)
    // After close the debt is fully repaid (closePosition would have reverted otherwise).
    // Assert that the collateral returned is within 5% of the vault NAV before close,
    // accounting for UniV3 swap fees and any pre-supplement collateral sold to cover shortfall.
    Test.assert(equalAmounts(a: collateralAfter, b: collateralBefore + vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "WFLOW close: expected ~".concat(vaultBalBefore.toString()).concat(" FLOW returned, collateralBefore=").concat(collateralBefore.toString()).concat(" collateralAfter=").concat(collateralAfter.toString()))
    log("WFLOW yield vault closed successfully, collateral returned: ".concat(collateralAfter.toString()))
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
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
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
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "WBTC withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WBTC vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WBTC() {
    let wbtcBalancePath: PublicPath = /public/EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579Receiver
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let collateralBefore = (_executeScript("../scripts/tokens/get_balance.cdc", [wbtcUser.address, wbtcBalancePath]).returnValue! as! UFix64?) ?? 0.0
    log("Closing WBTC vault ".concat(wbtcVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wbtcVaultID], [wbtcUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WBTC vault should no longer exist after close")
    let collateralAfter = (_executeScript("../scripts/tokens/get_balance.cdc", [wbtcUser.address, wbtcBalancePath]).returnValue! as! UFix64?) ?? 0.0
    // After close the debt is fully repaid (closePosition would have reverted otherwise).
    // Assert that the collateral returned is within 5% of the vault NAV before close.
    Test.assert(equalAmounts(a: collateralAfter, b: collateralBefore + vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "WBTC close: expected ~".concat(vaultBalBefore.toString()).concat(" WBTC returned, collateralBefore=").concat(collateralBefore.toString()).concat(" collateralAfter=").concat(collateralAfter.toString()))
    log("WBTC yield vault closed successfully, collateral returned: ".concat(collateralAfter.toString()))
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
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
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
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "WETH withdraw: expected ~".concat((before - withdrawAmount).toString()).concat(", got ").concat(after.toString()))
    log("WETH vault balance after withdrawal: ".concat(after.toString()))
}

access(all) fun testCloseFUSDEVYieldVault_WETH() {
    let wethBalancePath: PublicPath = /public/EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590Receiver
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let collateralBefore = (_executeScript("../scripts/tokens/get_balance.cdc", [wethUser.address, wethBalancePath]).returnValue! as! UFix64?) ?? 0.0
    log("Closing WETH vault ".concat(wethVaultID.toString()).concat(" (balance: ").concat(vaultBalBefore.toString()).concat(")..."))
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wethVaultID], [wethUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WETH vault should no longer exist after close")
    let collateralAfter = (_executeScript("../scripts/tokens/get_balance.cdc", [wethUser.address, wethBalancePath]).returnValue! as! UFix64?) ?? 0.0
    // After close the debt is fully repaid (closePosition would have reverted otherwise).
    // Assert that the collateral returned is within 5% of the vault NAV before close.
    Test.assert(equalAmounts(a: collateralAfter, b: collateralBefore + vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "WETH close: expected ~".concat(vaultBalBefore.toString()).concat(" WETH returned, collateralBefore=").concat(collateralBefore.toString()).concat(" collateralAfter=").concat(collateralAfter.toString()))
    log("WETH yield vault closed successfully, collateral returned: ".concat(collateralAfter.toString()))
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

/* =========================================================
   Excess-yield tests
   ========================================================= */

/// Opens a FUSDEVStrategy WFLOW vault, injects extra FUSDEV to create an excess scenario,
/// closes the vault, and verifies that the excess is returned as FLOW to the user.
///
/// Using FLOW as collateral makes the excess-return clearly visible: the user ends up with
/// more FLOW than they started with, because the injected FUSDEV shares are converted back
/// to FLOW (via FUSDEV → PYUSD0 → WFLOW) and added to the returned collateral.
///
/// Scenario:
///   1. Open a FUSDEVStrategy vault with 10.0 FLOW.
///   2. Convert 5.0 PYUSD0 → FUSDEV and deposit directly into the AutoBalancer.
///      (flowUser already holds PYUSD0 on mainnet — no transfer needed.)
///      → AutoBalancer balance now exceeds what is needed to repay the PYUSD0 debt.
///   3. Close the vault.
///      → Step 9 of closePosition() drains the remaining FUSDEV, converts it to
///        FLOW via MultiSwapper (FUSDEV → PYUSD0 → WFLOW), and adds it to the
///        returned collateral.
///   4. Verify flowAfter > flowBefore: the user gained net FLOW from the excess.
access(all) fun testCloseFUSDEVVaultWithExcessYieldTokens_WFLOW() {
    log("=== testCloseFUSDEVVaultWithExcessYieldTokens_WFLOW ===")

    let flowBefore = _flowBalance(flowUser)
    log("FLOW balance before vault creation: \(flowBefore)")

    let collateralAmount: UFix64 = 10.0
    log("Creating FUSDEVStrategy vault with \(collateralAmount) FLOW...")
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, flowVaultIdentifier, collateralAmount],
        [flowUser]
    )
    Test.expect(createResult, Test.beSucceeded())

    let vaultID = _latestVaultID(flowUser)
    log("Created vault ID: \(vaultID)")

    let vaultBalAfterCreate = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [flowUser.address, vaultID]
    )
    Test.expect(vaultBalAfterCreate, Test.beSucceeded())
    let vaultBal = vaultBalAfterCreate.returnValue! as! UFix64?
    Test.assert(equalAmounts(a: vaultBal!, b: collateralAmount, tolerance: collateralAmount * tolerancePct),
        message: "Expected vault balance ~\(collateralAmount) after create, got: \(vaultBal ?? 0.0)")
    log("Vault balance (FLOW collateral value): \(vaultBal!)")

    let abBalBefore = _autoBalancerBalance(vaultID)
    Test.assert(abBalBefore! > 0.0,
        message: "Expected positive AutoBalancer balance after vault creation, got: \(abBalBefore ?? 0.0)")
    log("AutoBalancer FUSDEV balance before injection: \(abBalBefore!)")

    // flowUser already holds PYUSD0 on mainnet — inject directly without a transfer.
    let injectionPYUSD0Amount: UFix64 = 5.0
    log("Injecting \(injectionPYUSD0Amount) PYUSD0 worth of FUSDEV into AutoBalancer...")
    let injectResult = _executeTransactionFile(
        "transactions/inject_pyusd0_as_fusdev_to_autobalancer.cdc",
        [vaultID, fusdEvEVMAddress, injectionPYUSD0Amount],
        [flowUser]
    )
    Test.expect(injectResult, Test.beSucceeded())

    let abBalAfter = _autoBalancerBalance(vaultID)
    Test.assert(abBalAfter != nil,
        message: "AutoBalancer should still exist after injection")
    Test.assert(abBalAfter! > abBalBefore!,
        message: "AutoBalancer FUSDEV balance should have increased after injection. Before: \(abBalBefore!) After: \(abBalAfter!)")
    let injectedShares = abBalAfter! - abBalBefore!
    log("AutoBalancer FUSDEV balance after injection: \(abBalAfter!)")
    log("Injected \(injectedShares) FUSDEV shares (excess over original debt coverage)")

    log("Closing vault \(vaultID)...")
    let closeResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [flowUser]
    )
    Test.expect(closeResult, Test.beSucceeded())

    let vaultBalAfterClose = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [flowUser.address, vaultID]
    )
    Test.expect(vaultBalAfterClose, Test.beSucceeded())
    Test.assert(vaultBalAfterClose.returnValue == nil,
        message: "Vault \(vaultID) should not exist after close")
    log("Vault no longer exists — close confirmed")

    let abBalFinal = _autoBalancerBalance(vaultID)
    Test.assert(abBalFinal == nil,
        message: "AutoBalancer should be nil (burned) after vault close, but got: \(abBalFinal ?? 0.0)")
    log("AutoBalancer is nil after close — torn down during _cleanupAutoBalancer")

    let flowAfter = _flowBalance(flowUser)
    log("FLOW balance after close: \(flowAfter)")

    // 5 PYUSD0 ≈ $5 at current prices — well above tx fees incurred during this test.
    // The net gain should be clearly positive: excess FUSDEV → PYUSD0 → WFLOW adds more
    // FLOW back than the transactions consume in fees.
    Test.assert(
        flowAfter > flowBefore,
        message: "User should have more FLOW than before (excess FUSDEV converted back to FLOW). Before: \(flowBefore), After: \(flowAfter)"
    )
    let flowNet = flowAfter - flowBefore
    log("Net FLOW gain from excess FUSDEV conversion: \(flowNet) FLOW (injected ~\(injectionPYUSD0Amount) PYUSD0 worth)")

    log("=== testCloseFUSDEVVaultWithExcessYieldTokens_WFLOW PASSED ===")
}

/// Reconfiguring the close route after vault creation must cause close to fail rather than burn
/// non-empty excess yield on a zero quote.
access(all) fun testCloseFUSDEVVaultWithBrokenCloseRouteFailsInsteadOfBurning() {
    log("=== testCloseFUSDEVVaultWithBrokenCloseRouteFailsInsteadOfBurning ===")

    // Open a normal FLOW-collateral FUSDEV vault first, so close would succeed under the
    // original configuration.
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [fusdEvStrategyIdentifier, flowVaultIdentifier, 10.0],
        [flowUser]
    )
    Test.expect(createResult, Test.beSucceeded())

    let vaultID = _latestVaultID(flowUser)
    log("Created vault ID: \(vaultID)")

    // Inject excess FUSDEV into the AutoBalancer so closePosition must process a non-empty
    // excess-yield branch. This is the value that would have been silently burned before the
    // revert-on-zero-quote change.
    let injectResult = _executeTransactionFile(
        "transactions/inject_pyusd0_as_fusdev_to_autobalancer.cdc",
        [vaultID, fusdEvEVMAddress, 5.0],
        [flowUser]
    )
    Test.expect(injectResult, Test.beSucceeded())

    // Break the close route after the vault already exists by repointing FLOW collateral to a
    // WBTC-ending path. This preserves the mutable-config scenario we want to probe: the vault
    // was opened with a valid route, but close now reconstructs a different one.
    let misconfigureResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc",
        [
            fusdEvStrategyIdentifier,
            flowVaultIdentifier,
            fusdEvEVMAddress,
            [fusdEvEVMAddress, pyusd0EVMAddress, wbtcEVMAddress],
            [100 as UInt32, 3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(misconfigureResult, Test.beSucceeded())

    // The important assertion: close must fail, not "succeed" by burning the excess FUSDEV or
    // any returned non-collateral residuals when the rebuilt route cannot quote a conversion.
    let failedClose = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [flowUser]
    )
    Test.expect(failedClose, Test.beFailed())

    // Restore the original close route and prove the same vault can still be closed afterward.
    // That shows the failed close did not destroy value or corrupt the vault state irreversibly.
    let restoreResult = _executeTransactionFile(
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
    Test.expect(restoreResult, Test.beSucceeded())

    let successfulClose = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [flowUser]
    )
    Test.expect(successfulClose, Test.beSucceeded())

    let vaultBalAfterClose = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [flowUser.address, vaultID]
    )
    Test.expect(vaultBalAfterClose, Test.beSucceeded())
    // Final proof: the vault disappears only after the valid-route close, not after the broken
    // close attempt.
    Test.assert(vaultBalAfterClose.returnValue == nil,
        message: "Vault \(vaultID) should not exist after restored-route close")
}
