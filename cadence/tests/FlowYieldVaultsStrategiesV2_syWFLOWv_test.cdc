#test_fork(network: "mainnet", height: nil)

import Test

import "EVM"
import "FlowToken"
import "FlowALPv0"
import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"

/// Fork test for FlowYieldVaultsStrategiesV2 syWFLOWvStrategy.
///
/// Tests the full YieldVault lifecycle (create, deposit, withdraw, close) for each supported
/// collateral type: PYUSD0, WBTC, and WETH.
///
/// FLOW cannot be used as collateral — it is the vault's underlying / debt asset.
///
/// Strategy:
///   <collateral> → FlowALP borrow FLOW → ERC4626 deposit → syWFLOWv (More vault)
///   Close: syWFLOWv → FLOW via UniV3 (repay) → <collateral> returned to user
///
/// Mainnet addresses:
///   - Admin (FlowYieldVaults deployer): 0xb1d63873c3cc9f79
///   - PYUSD0 user: 0x443472749ebdaac8 (pre-holds PYUSD0 on mainnet)
///   - WBTC/WETH user: 0x68da18f20e98a7b6 (has ~12 WETH in EVM COA; WETH bridged + WBTC swapped in setup)
///   - UniV3 Factory: 0xca6d7Bb03334bBf135902e1d919a5feccb461632
///   - UniV3 Router:  0xeEDC6Ff75e1b10B903D9013c358e446a73d35341
///   - UniV3 Quoter:  0x370A8DF17742867a44e56223EC20D82092242C85
///   - WFLOW:   0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e
///   - syWFLOWv (More vault): 0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597
///   - PYUSD0:  0x99aF3EeA856556646C98c8B9b2548Fe815240750
///   - WBTC:    0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579 (cbBTC, no WFLOW pool; use WETH as intermediate)
///   - WETH:    0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590 (WFLOW/WETH pool fee 3000 exists)

// --- Accounts ---

/// Mainnet admin account — deployer of FlowYieldVaults, FlowYieldVaultsClosedBeta, FlowYieldVaultsStrategiesV2
access(all) let adminAccount = Test.getAccount(0xb1d63873c3cc9f79)

/// PYUSD0 holder on mainnet
access(all) let pyusd0User = Test.getAccount(0x443472749ebdaac8)

/// WBTC/WETH holder — this account has ~12 WETH in its EVM COA on mainnet.
/// WETH is bridged to Cadence during setup(), and some WETH is then swapped → WBTC
/// via the UniV3 WETH/WBTC pool so that both collateral types can be tested.
/// COA EVM: 0x000000000000000000000002b87c966bc00bc2c4
access(all) let wbtcUser = Test.getAccount(0x68da18f20e98a7b6)
access(all) let wethUser = Test.getAccount(0x68da18f20e98a7b6)

// --- Strategy Config ---

access(all) let syWFLOWvStrategyIdentifier = "A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.syWFLOWvStrategy"
access(all) let composerIdentifier = "A.b1d63873c3cc9f79.FlowYieldVaultsStrategiesV2.MoreERC4626StrategyComposer"
access(all) let issuerStoragePath: StoragePath = /storage/FlowYieldVaultsStrategyV2ComposerIssuer_0xb1d63873c3cc9f79

// --- Cadence Vault Type Identifiers (VM-bridged ERC-20s) ---

access(all) let pyusd0VaultIdentifier = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"
access(all) let wbtcVaultIdentifier   = "A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault"
access(all) let wethVaultIdentifier   = "A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault"

// --- EVM Addresses ---

access(all) let syWFLOWvEVMAddress = "0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"
access(all) let wflowEVMAddress    = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
access(all) let pyusd0EVMAddress   = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let wbtcEVMAddress     = "0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579"
access(all) let wethEVMAddress     = "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"

// --- Test State (vault IDs set during create tests, read by subsequent tests) ---

access(all) var pyusd0VaultID: UInt64 = 0
access(all) var wbtcVaultID:   UInt64 = 0
access(all) var wethVaultID:   UInt64 = 0

/// Relative tolerance used in all balance assertions (0.1%).
access(all) let tolerancePct: UFix64 = 0.001


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

/// Returns the latest yield vault ID for the given account, or panics if none found.
access(all)
fun _latestVaultID(_ user: Test.TestAccount): UInt64 {
    let r = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_ids.cdc", [user.address])
    Test.expect(r, Test.beSucceeded())
    let ids = r.returnValue! as! [UInt64]?
    Test.assert(ids != nil && ids!.length > 0, message: "Expected at least one yield vault for \(user.address)")
    return ids![ids!.length - 1]
}

/// Returns the syWFLOWv share balance held in the AutoBalancer for the given vault ID,
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

/// Returns the PYUSD0 Cadence vault balance for the given account.
access(all)
fun _pyusd0Balance(_ user: Test.TestAccount): UFix64 {
    let r = _executeScript("../scripts/tokens/get_vault_balance_by_type.cdc", [user.address, pyusd0VaultIdentifier])
    Test.expect(r, Test.beSucceeded())
    return (r.returnValue as? UFix64) ?? 0.0
}

/// Returns the WBTC Cadence vault balance for the given account.
access(all)
fun _wbtcBalance(_ user: Test.TestAccount): UFix64 {
    let r = _executeScript("../scripts/tokens/get_vault_balance_by_type.cdc", [user.address, wbtcVaultIdentifier])
    Test.expect(r, Test.beSucceeded())
    return (r.returnValue as? UFix64) ?? 0.0
}

/* --- Setup --- */

access(all) fun setup() {
    log("==== FlowYieldVaultsStrategiesV2 syWFLOWv Fork Test Setup ====")

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

    log("Deploying ERC4626PriceOracles...")
    err = Test.deployContract(
        name: "ERC4626PriceOracles",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626PriceOracles.cdc",
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

    log("Deploying FlowALPv0...")
    err = Test.deployContract(
        name: "FlowALPv0",
        path: "../../lib/FlowALP/cadence/contracts/FlowALPv0.cdc",
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

    // yieldToUnderlying path is the same for all collaterals: syWFLOWv → WFLOW via UniV3 fee 100 (0.01%)
    // debtToCollateral paths differ per collateral: WFLOW → <collateral>

    log("Configuring MoreERC4626CollateralConfig: syWFLOWvStrategy + PYUSD0 (WFLOW→PYUSD0 fee 3000)...")
    var result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc",
        [
            syWFLOWvStrategyIdentifier,
            pyusd0VaultIdentifier,
            syWFLOWvEVMAddress,
            [syWFLOWvEVMAddress, wflowEVMAddress],  // yieldToUnderlying
            [100 as UInt32],
            [wflowEVMAddress, pyusd0EVMAddress],     // debtToCollateral
            [3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // No WFLOW/WBTC pool exists on Flow EVM; use 2-hop path WFLOW→WETH→WBTC instead.
    log("Configuring MoreERC4626CollateralConfig: syWFLOWvStrategy + WBTC (WFLOW→WETH→WBTC fee 3000/3000)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc",
        [
            syWFLOWvStrategyIdentifier,
            wbtcVaultIdentifier,
            syWFLOWvEVMAddress,
            [syWFLOWvEVMAddress, wflowEVMAddress],           // yieldToUnderlying: syWFLOWv→WFLOW
            [100 as UInt32],
            [wflowEVMAddress, wethEVMAddress, wbtcEVMAddress], // debtToCollateral: WFLOW→WETH→WBTC
            [3000 as UInt32, 3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    log("Configuring MoreERC4626CollateralConfig: syWFLOWvStrategy + WETH (WFLOW→WETH fee 3000)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc",
        [
            syWFLOWvStrategyIdentifier,
            wethVaultIdentifier,
            syWFLOWvEVMAddress,
            [syWFLOWvEVMAddress, wflowEVMAddress],  // yieldToUnderlying
            [100 as UInt32],
            [wflowEVMAddress, wethEVMAddress],       // debtToCollateral
            [3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Register syWFLOWvStrategy in the FlowYieldVaults StrategyFactory
    log("Registering syWFLOWvStrategy in FlowYieldVaults factory...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/add_strategy_composer.cdc",
        [syWFLOWvStrategyIdentifier, composerIdentifier, issuerStoragePath],
        [adminAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Grant beta access to all user accounts
    log("Granting beta access to PYUSD0 user...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, pyusd0User]
    )
    Test.expect(result, Test.beSucceeded())

    log("Granting beta access to WBTC/WETH user (0x68da18f20e98a7b6)...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    // Add FLOW reserves to the FlowALP pool.
    // The mainnet pool at 0x6b00ff876c299c61 only has ~12 FLOW at the fork height —
    // not enough for WBTC/WETH vaults (WBTC ~$9 needs ~125 FLOW; WETH ~$2.5 needs ~35 FLOW).
    // wbtcUser holds 1.38M FLOW in Cadence storage, so we grant them pool access and
    // have them create a 10,000-FLOW reserve position.
    let alpAdmin = Test.getAccount(0x6b00ff876c299c61)
    log("Granting wbtcUser FlowALP pool cap for reserve position...")
    result = _executeTransactionFile(
        "../../lib/FlowALP/cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc",
        [],
        [alpAdmin, wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    log("Creating 10,000 FLOW reserve position in FlowALP pool...")
    result = _executeTransactionFile(
        "../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
        [10000.0 as UFix64, /storage/flowTokenVault, true as Bool],
        [wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    // Provision WETH: bridge ~2 WETH from the COA (EVM) to Cadence storage.
    // The COA at 0x000000000000000000000002b87c966bc00bc2c4 holds ~12 WETH on mainnet.
    log("Bridging 2 WETH from COA to Cadence for WBTC/WETH user...")
    // 2 WETH = 2_000_000_000_000_000_000 (18 decimals)
    result = _executeTransactionFile(
        "../../lib/FlowALP/FlowActions/cadence/tests/transactions/bridge/bridge_tokens_from_evm.cdc",
        [wethVaultIdentifier, 2000000000000000000 as UInt256],
        [wethUser]
    )
    Test.expect(result, Test.beSucceeded())

    // Provision WBTC: swap 0.1 WETH → WBTC via the UniV3 WETH/WBTC pool (fee 3000).
    log("Swapping 0.1 WETH → WBTC for WBTC test user...")
    result = _executeTransactionFile(
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
    Test.expect(result, Test.beSucceeded())

    log("==== Setup Complete ====")
}

/* =========================================================
   PYUSD0 collateral lifecycle
   ========================================================= */

access(all) fun testCreateSyWFLOWvYieldVault_PYUSD0() {
    let collateralAmount: UFix64 = 2.0
    log("Creating syWFLOWvStrategy yield vault with \(collateralAmount) PYUSD0...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, pyusd0VaultIdentifier, collateralAmount],
        [pyusd0User]
    )
    Test.expect(result, Test.beSucceeded())

    pyusd0VaultID = _latestVaultID(pyusd0User)
    log("Created PYUSD0 vault ID: \(pyusd0VaultID)")

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(equalAmounts(a: balance!, b: collateralAmount, tolerance: collateralAmount * tolerancePct),
        message: "PYUSD0 vault balance after create should be ~\(collateralAmount), got \(balance!)")
    log("PYUSD0 vault balance after create: \(balance!)")

    // Verify PYUSD0 was deposited directly into FlowALP as collateral (no intermediate token swap).
    // syWFLOWvStrategy does not involve MOET at any point — PYUSD0 is deposited as-is.
    //   - There must be a Deposited event with vaultType = PYUSD0 (collateral deposited directly)
    //   - There must be NO Deposited event with vaultType = MOET (no pre-swap should occur)
    let depositedEvents = Test.eventsOfType(Type<FlowALPv0.Deposited>())
    log("FlowALPv0.Deposited events: \(depositedEvents.length)")

    let moetTypeID = "A.6b00ff876c299c61.MOET.Vault"
    var foundMoetDeposit = false
    var foundPyusd0Deposit = false
    for e in depositedEvents {
        let ev = e as! FlowALPv0.Deposited
        log("  Deposited: vaultType=\(ev.vaultType.identifier) amount=\(ev.amount)")
        if ev.vaultType.identifier == moetTypeID {
            foundMoetDeposit = true
        }
        if ev.vaultType.identifier == pyusd0VaultIdentifier {
            foundPyusd0Deposit = true
        }
    }
    Test.assert(foundPyusd0Deposit,
        message: "Expected FlowALPv0.Deposited event with PYUSD0 — PYUSD0 collateral was not deposited into FlowALP")
    Test.assert(!foundMoetDeposit,
        message: "Unexpected FlowALPv0.Deposited event with MOET — syWFLOWvStrategy should not involve MOET")
    log("Confirmed: FlowALP received PYUSD0 directly as collateral (no MOET involvement)")
}

access(all) fun testDepositToSyWFLOWvYieldVault_PYUSD0() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 0.5
    log("Depositing 0.5 PYUSD0 to vault \(pyusd0VaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [pyusd0VaultID, depositAmount], [pyusd0User]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
        message: "PYUSD0 deposit: expected ~\(before + depositAmount), got \(after)")
    log("PYUSD0 vault balance after deposit: \(after)")
}

access(all) fun testWithdrawFromSyWFLOWvYieldVault_PYUSD0() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 0.3
    log("Withdrawing 0.3 PYUSD0 from vault \(pyusd0VaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [pyusd0VaultID, withdrawAmount], [pyusd0User]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "PYUSD0 withdraw: expected ~\(before - withdrawAmount), got \(after)")
    log("PYUSD0 vault balance after withdrawal: \(after)")
}

access(all) fun testCloseSyWFLOWvYieldVault_PYUSD0() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID]).returnValue! as! UFix64?) ?? 0.0
    let userBalBefore = _pyusd0Balance(pyusd0User)
    log("Closing PYUSD0 vault \(pyusd0VaultID) (balance: \(vaultBalBefore), user PYUSD0: \(userBalBefore))...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [pyusd0VaultID], [pyusd0User]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [pyusd0User.address, pyusd0VaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "PYUSD0 vault should no longer exist after close")
    let userBalAfter = _pyusd0Balance(pyusd0User)
    let returned = userBalAfter - userBalBefore
    Test.assert(equalAmounts(a: returned, b: vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "Expected ~\(vaultBalBefore) PYUSD0 returned on close, got \(returned)")
    log("PYUSD0 yield vault closed — returned \(returned) PYUSD0 (vault had \(vaultBalBefore))")
}

/* =========================================================
   WBTC collateral lifecycle
   ========================================================= */

access(all) fun testCreateSyWFLOWvYieldVault_WBTC() {
    let collateralAmount: UFix64 = 0.0001
    log("Creating syWFLOWvStrategy yield vault with \(collateralAmount) WBTC...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, wbtcVaultIdentifier, collateralAmount],
        [wbtcUser]
    )
    Test.expect(result, Test.beSucceeded())

    wbtcVaultID = _latestVaultID(wbtcUser)
    log("Created WBTC vault ID: \(wbtcVaultID)")

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(equalAmounts(a: balance!, b: collateralAmount, tolerance: collateralAmount * tolerancePct),
        message: "WBTC vault balance after create should be ~\(collateralAmount), got \(balance!)")
    log("WBTC vault balance after create: \(balance!)")
}

access(all) fun testDepositToSyWFLOWvYieldVault_WBTC() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 0.00005
    log("Depositing 0.00005 WBTC to vault \(wbtcVaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [wbtcVaultID, depositAmount], [wbtcUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
        message: "WBTC deposit: expected ~\(before + depositAmount), got \(after)")
    log("WBTC vault balance after deposit: \(after)")
}

access(all) fun testWithdrawFromSyWFLOWvYieldVault_WBTC() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 0.00003
    log("Withdrawing 0.00003 WBTC from vault \(wbtcVaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [wbtcVaultID, withdrawAmount], [wbtcUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "WBTC withdraw: expected ~\(before - withdrawAmount), got \(after)")
    log("WBTC vault balance after withdrawal: \(after)")
}

access(all) fun testCloseSyWFLOWvYieldVault_WBTC() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID]).returnValue! as! UFix64?) ?? 0.0
    let userBalBefore = _wbtcBalance(wbtcUser)
    log("Closing WBTC vault \(wbtcVaultID) (balance: \(vaultBalBefore), user WBTC: \(userBalBefore))...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wbtcVaultID], [wbtcUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wbtcUser.address, wbtcVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WBTC vault should no longer exist after close")
    let userBalAfter = _wbtcBalance(wbtcUser)
    let returned = userBalAfter - userBalBefore
    Test.assert(equalAmounts(a: returned, b: vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "Expected ~\(vaultBalBefore) WBTC returned on close, got \(returned)")
    log("WBTC yield vault closed — returned \(returned) WBTC (vault had \(vaultBalBefore))")
}

/* =========================================================
   WETH collateral lifecycle
   ========================================================= */

access(all) fun testCreateSyWFLOWvYieldVault_WETH() {
    let collateralAmount: UFix64 = 0.001
    log("Creating syWFLOWvStrategy yield vault with \(collateralAmount) WETH...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, wethVaultIdentifier, collateralAmount],
        [wethUser]
    )
    Test.expect(result, Test.beSucceeded())

    wethVaultID = _latestVaultID(wethUser)
    log("Created WETH vault ID: \(wethVaultID)")

    let bal = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID])
    Test.expect(bal, Test.beSucceeded())
    let balance = bal.returnValue! as! UFix64?
    Test.assert(equalAmounts(a: balance!, b: collateralAmount, tolerance: collateralAmount * tolerancePct),
        message: "WETH vault balance after create should be ~\(collateralAmount), got \(balance!)")
    log("WETH vault balance after create: \(balance!)")
}

access(all) fun testDepositToSyWFLOWvYieldVault_WETH() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let depositAmount: UFix64 = 0.0005
    log("Depositing 0.0005 WETH to vault \(wethVaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc", [wethVaultID, depositAmount], [wethUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before + depositAmount, tolerance: (before + depositAmount) * tolerancePct),
        message: "WETH deposit: expected ~\(before + depositAmount), got \(after)")
    log("WETH vault balance after deposit: \(after)")
}

access(all) fun testWithdrawFromSyWFLOWvYieldVault_WETH() {
    let before = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let withdrawAmount: UFix64 = 0.0003
    log("Withdrawing 0.0003 WETH from vault \(wethVaultID)...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc", [wethVaultID, withdrawAmount], [wethUser]),
        Test.beSucceeded()
    )
    let after = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?)!
    Test.assert(equalAmounts(a: after, b: before - withdrawAmount, tolerance: (before - withdrawAmount) * tolerancePct),
        message: "WETH withdraw: expected ~\(before - withdrawAmount), got \(after)")
    log("WETH vault balance after withdrawal: \(after)")
}

access(all) fun testCloseSyWFLOWvYieldVault_WETH() {
    let vaultBalBefore = (_executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID]).returnValue! as! UFix64?) ?? 0.0
    let userBalBefore = _wethBalance(wethUser)
    log("Closing WETH vault \(wethVaultID) (balance: \(vaultBalBefore), user WETH: \(userBalBefore))...")
    Test.expect(
        _executeTransactionFile("../transactions/flow-yield-vaults/close_yield_vault.cdc", [wethVaultID], [wethUser]),
        Test.beSucceeded()
    )
    let vaultBalAfter = _executeScript("../scripts/flow-yield-vaults/get_yield_vault_balance.cdc", [wethUser.address, wethVaultID])
    Test.expect(vaultBalAfter, Test.beSucceeded())
    Test.assert(vaultBalAfter.returnValue == nil, message: "WETH vault should no longer exist after close")
    let userBalAfter = _wethBalance(wethUser)
    let returned = userBalAfter - userBalBefore
    Test.assert(equalAmounts(a: returned, b: vaultBalBefore, tolerance: vaultBalBefore * tolerancePct),
        message: "Expected ~\(vaultBalBefore) WETH returned on close, got \(returned)")
    log("WETH yield vault closed — returned \(returned) WETH (vault had \(vaultBalBefore))")
}

/* =========================================================
   Negative tests
   ========================================================= */

/// FLOW is the underlying / debt asset of syWFLOWvStrategy — it must be rejected as collateral.
access(all) fun testCannotCreateYieldVaultWithFLOWAsCollateral() {
    let flowVaultIdentifier = "A.1654653399040a61.FlowToken.Vault"
    log("Attempting to create syWFLOWvStrategy vault with FLOW (debt asset) as collateral — expecting failure...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, flowVaultIdentifier, 1.0],
        [pyusd0User]
    )
    Test.expect(result, Test.beFailed())
    log("Correctly rejected FLOW as collateral")
}

/// Depositing the wrong token type into an existing YieldVault must be rejected.
/// Here wethUser owns both WETH and WBTC (set up in setup()).
/// We create a WETH vault, then attempt to deposit WBTC into it — the strategy pre-condition should panic.
access(all) fun testCannotDepositWrongTokenToYieldVault() {
    log("Creating a fresh WETH vault for wrong-token deposit test...")
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, wethVaultIdentifier, 0.001],
        [wethUser]
    )
    Test.expect(createResult, Test.beSucceeded())
    let freshWethVaultID = _latestVaultID(wethUser)
    log("Created WETH vault ID: \(freshWethVaultID) — now attempting to deposit WBTC into it...")

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
   Excess-yield test
   ========================================================= */

/// Opens a syWFLOWvStrategy PYUSD0 vault, injects extra syWFLOWv to create an excess scenario,
/// closes the vault, and verifies that the excess is returned as PYUSD0 to the user.
///
/// Using PYUSD0 as collateral makes the excess-return clearly visible: the user ends up with
/// more PYUSD0 than they started with, because the injected syWFLOWv shares are converted back
/// to PYUSD0 (via syWFLOWv → FLOW → PYUSD0) and added to the returned collateral.
///
/// Scenario:
///   1. Open a syWFLOWvStrategy vault with 2.0 PYUSD0.
///   2. Convert 50 FLOW → syWFLOWv and deposit directly into the AutoBalancer.
///      (pyusd0User already holds FLOW on mainnet — no setup needed.)
///      → AutoBalancer balance now exceeds what is needed to repay the FLOW debt.
///   3. Close the vault.
///      → Step 8 of closePosition() drains the remaining syWFLOWv, converts it to
///        PYUSD0 (syWFLOWv → FLOW → PYUSD0), and adds it to the returned collateral.
///   4. Verify pyusd0After > pyusd0Before: the user gained net PYUSD0 from the excess.
access(all) fun testCloseSyWFLOWvVaultWithExcessYieldTokens_PYUSD0() {
    log("=== testCloseSyWFLOWvVaultWithExcessYieldTokens_PYUSD0 ===")

    let pyusd0Before = _pyusd0Balance(pyusd0User)
    log("PYUSD0 balance before vault creation: \(pyusd0Before)")

    let collateralAmount: UFix64 = 2.0
    log("Creating syWFLOWvStrategy vault with \(collateralAmount) PYUSD0...")
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, pyusd0VaultIdentifier, collateralAmount],
        [pyusd0User]
    )
    Test.expect(createResult, Test.beSucceeded())

    let vaultID = _latestVaultID(pyusd0User)
    log("Created vault ID: \(vaultID)")

    let vaultBalAfterCreate = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [pyusd0User.address, vaultID]
    )
    Test.expect(vaultBalAfterCreate, Test.beSucceeded())
    let vaultBal = vaultBalAfterCreate.returnValue! as! UFix64?
    Test.assert(equalAmounts(a: vaultBal!, b: collateralAmount, tolerance: collateralAmount * tolerancePct),
        message: "Expected vault balance ~\(collateralAmount) after create, got: \(vaultBal ?? 0.0)")
    log("Vault balance (PYUSD0 collateral value): \(vaultBal!)")

    let abBalBefore = _autoBalancerBalance(vaultID)
    Test.assert(abBalBefore! > 0.0,
        message: "Expected positive AutoBalancer balance after vault creation, got: \(abBalBefore ?? 0.0)")
    log("AutoBalancer syWFLOWv balance before injection: \(abBalBefore!)")

    // pyusd0User holds FLOW on mainnet — inject directly without any setup.
    let injectionFlowAmount: UFix64 = 10.0
    log("Injecting \(injectionFlowAmount) FLOW worth of syWFLOWv into AutoBalancer...")
    let injectResult = _executeTransactionFile(
        "transactions/inject_flow_as_sywflowv_to_autobalancer.cdc",
        [vaultID, syWFLOWvEVMAddress, injectionFlowAmount],
        [pyusd0User]
    )
    Test.expect(injectResult, Test.beSucceeded())

    let abBalAfter = _autoBalancerBalance(vaultID)
    Test.assert(abBalAfter != nil,
        message: "AutoBalancer should still exist after injection")
    Test.assert(abBalAfter! > abBalBefore!,
        message: "AutoBalancer balance should have increased after injection. Before: \(abBalBefore!) After: \(abBalAfter!)")
    let injectedShares = abBalAfter! - abBalBefore!
    log("AutoBalancer syWFLOWv balance after injection: \(abBalAfter!)")
    log("Injected \(injectedShares) syWFLOWv shares (excess over original debt coverage)")

    log("Closing vault \(vaultID)...")
    let closeResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [pyusd0User]
    )
    Test.expect(closeResult, Test.beSucceeded())

    let vaultBalAfterClose = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [pyusd0User.address, vaultID]
    )
    Test.expect(vaultBalAfterClose, Test.beSucceeded())
    Test.assert(vaultBalAfterClose.returnValue == nil,
        message: "Vault \(vaultID) should not exist after close")
    log("Vault no longer exists — close confirmed")

    let abBalFinal = _autoBalancerBalance(vaultID)
    Test.assert(abBalFinal == nil,
        message: "AutoBalancer should be nil (burned) after vault close, but got: \(abBalFinal ?? 0.0)")
    log("AutoBalancer is nil after close — torn down during _cleanupAutoBalancer")

    let pyusd0After = _pyusd0Balance(pyusd0User)
    log("PYUSD0 balance after close: \(pyusd0After)")

    // 10 FLOW ≈ $0.3–0.5 at current prices — well above tx fees incurred during this test.
    // The net gain should be clearly positive: excess syWFLOWv → FLOW → PYUSD0 adds more
    // PYUSD0 back than the transactions consume in fees.
    Test.assert(
        pyusd0After > pyusd0Before,
        message: "User should have more PYUSD0 than before (excess syWFLOWv converted back to PYUSD0). Before: \(pyusd0Before), After: \(pyusd0After)"
    )
    let pyusd0Net = pyusd0After - pyusd0Before
    log("Net PYUSD0 gain from excess syWFLOWv conversion: \(pyusd0Net) PYUSD0 (injected ~\(injectionFlowAmount) FLOW worth)")

    log("=== testCloseSyWFLOWvVaultWithExcessYieldTokens_PYUSD0 PASSED ===")
}

/// Reconfiguring the close route after vault creation must cause close to fail rather than burn
/// non-empty excess yield on a zero quote.
access(all) fun testCloseSyWFLOWvVaultWithBrokenCloseRouteFailsInsteadOfBurning() {
    log("=== testCloseSyWFLOWvVaultWithBrokenCloseRouteFailsInsteadOfBurning ===")

    // Open a normal PYUSD0-collateral syWFLOWv vault first, so close would succeed under the
    // original configuration.
    let createResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, pyusd0VaultIdentifier, 2.0],
        [pyusd0User]
    )
    Test.expect(createResult, Test.beSucceeded())

    let vaultID = _latestVaultID(pyusd0User)
    log("Created vault ID: \(vaultID)")

    // Inject excess syWFLOWv into the AutoBalancer so closePosition must process a non-empty
    // excess-yield branch. This is the value that would have been silently burned before the
    // revert-on-zero-quote change.
    let injectResult = _executeTransactionFile(
        "transactions/inject_flow_as_sywflowv_to_autobalancer.cdc",
        [vaultID, syWFLOWvEVMAddress, 10.0],
        [pyusd0User]
    )
    Test.expect(injectResult, Test.beSucceeded())

    // Break the close route after the vault already exists by repointing PYUSD0 collateral to a
    // WBTC-ending debtToCollateral path. This exercises the mutable-config scenario directly.
    let misconfigureResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc",
        [
            syWFLOWvStrategyIdentifier,
            pyusd0VaultIdentifier,
            syWFLOWvEVMAddress,
            [syWFLOWvEVMAddress, wflowEVMAddress],
            [100 as UInt32],
            [wflowEVMAddress, wbtcEVMAddress],
            [3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(misconfigureResult, Test.beSucceeded())

    // The important assertion: close must fail, not "succeed" by burning excess syWFLOWv or
    // returned FLOW residuals when the rebuilt route cannot quote a conversion.
    let failedClose = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [pyusd0User]
    )
    Test.expect(failedClose, Test.beFailed())

    // Restore the original close route and prove the same vault can still be closed afterward.
    // That shows the failed close did not destroy value or corrupt the vault state irreversibly.
    let restoreResult = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/upsert_more_erc4626_config.cdc",
        [
            syWFLOWvStrategyIdentifier,
            pyusd0VaultIdentifier,
            syWFLOWvEVMAddress,
            [syWFLOWvEVMAddress, wflowEVMAddress],
            [100 as UInt32],
            [wflowEVMAddress, pyusd0EVMAddress],
            [3000 as UInt32]
        ],
        [adminAccount]
    )
    Test.expect(restoreResult, Test.beSucceeded())

    let successfulClose = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [vaultID],
        [pyusd0User]
    )
    Test.expect(successfulClose, Test.beSucceeded())

    let vaultBalAfterClose = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [pyusd0User.address, vaultID]
    )
    Test.expect(vaultBalAfterClose, Test.beSucceeded())
    // Final proof: the vault disappears only after the valid-route close, not after the broken
    // close attempt.
    Test.assert(vaultBalAfterClose.returnValue == nil,
        message: "Vault \(vaultID) should not exist after restored-route close")
}
