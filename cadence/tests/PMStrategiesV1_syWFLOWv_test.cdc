#test_fork(network: "mainnet", height: nil)  // Uses latest height - syWFLOWv works well at recent heights

import Test

import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "PMStrategiesV1"
import "FlowYieldVaultsClosedBeta"

/// Fork test for PMStrategiesV1 syWFLOWv strategy — validates the full YieldVault lifecycle
/// (create, deposit, withdraw, close) against real mainnet state.
///
/// This test:
///   - Forks Flow mainnet to access real EVM state (Morpho vaults, UniswapV3 pools)
///   - Configures PMStrategiesV1 syWFLOWv strategy (FLOW collateral -> syWFLOWv Morpho ERC4626 vault)
///   - Tests the complete yield vault lifecycle
///   - Validates Morpho ERC4626 swap connectors work with real vault contracts
///
/// Mainnet addresses:
///   - Admin (FlowYieldVaults deployer): 0xb1d63873c3cc9f79
///   - UniV3 Factory: 0xca6d7Bb03334bBf135902e1d919a5feccb461632
///   - UniV3 Router:  0xeEDC6Ff75e1b10B903D9013c358e446a73d35341
///   - UniV3 Quoter:  0x370A8DF17742867a44e56223EC20D82092242C85
///   - WFLOW:   0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e
///   - syWFLOWv (More vault): 0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597

// --- Accounts ---

/// Mainnet admin account — deployer of PMStrategiesV1, FlowYieldVaults, FlowYieldVaultsClosedBeta
access(all) let adminAccount = Test.getAccount(0xb1d63873c3cc9f79)

/// Mainnet user account — used to test yield vault operations
access(all) let userAccount = Test.getAccount(0x443472749ebdaac8)

// --- Strategy Config Constants ---

/// syWFLOWvStrategy: FLOW collateral -> syWFLOWv Morpho ERC4626 vault
access(all) let syWFLOWvStrategyIdentifier = "A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy"
access(all) let flowVaultIdentifier = "A.1654653399040a61.FlowToken.Vault"
access(all) let syWFLOWvEVMAddress = "0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"

/// ERC4626VaultStrategyComposer type and issuer path
access(all) let composerIdentifier = "A.b1d63873c3cc9f79.PMStrategiesV1.ERC4626VaultStrategyComposer"
access(all) let issuerStoragePath: StoragePath = /storage/PMStrategiesV1ComposerIssuer_0xb1d63873c3cc9f79

/// Swap fee tier for Morpho vault <-> underlying asset UniV3 pools
access(all) let swapFeeTier: UInt32 = 100

// --- Test State ---

access(all) var syWFLOWvYieldVaultID: UInt64 = 0

/* --- Test Helpers --- */

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
    if a > b {
        return a - b <= tolerance
    }
    return b - a <= tolerance
}

/* --- Setup --- */

access(all) fun setup() {
    log("==== PMStrategiesV1 syWFLOWv Fork Test Setup ====")

    log("Deploying EVMAmountUtils contract ...")
    var err = Test.deployContract(
        name: "EVMAmountUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/EVMAmountUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying UniswapV3SwapConnectors contract ...")
    err = Test.deployContract(
        name: "UniswapV3SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Deploy Morpho contracts (latest local code) to the forked environment
    log("Deploying Morpho contracts...")
    err = Test.deployContract(
        name: "ERC4626Utils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/ERC4626Utils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "ERC4626SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/ERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MorphoERC4626SinkConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SinkConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MorphoERC4626SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    log("Deploying FlowYieldVaults contract ...")
    err = Test.deployContract(
        name: "FlowYieldVaults",
        path: "../../cadence/contracts/FlowYieldVaults.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Redeploy PMStrategiesV1 with latest local code to override mainnet version
    log("Deploying PMStrategiesV1...")
    err = Test.deployContract(
        name: "PMStrategiesV1",
        path: "../../cadence/contracts/PMStrategiesV1.cdc",
        arguments: [
            "0xca6d7Bb03334bBf135902e1d919a5feccb461632",
            "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341",
            "0x370A8DF17742867a44e56223EC20D82092242C85"
        ]
    )
    Test.expect(err, Test.beNil())

    // Grant beta access to user account for testing yield vault operations
    log("Granting beta access to user...")
    var result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    log("==== Setup Complete ====")
}

/* --- syWFLOWvStrategy Tests (FLOW collateral, Morpho syWFLOWv vault) --- */

access(all) fun testCreateSyWFLOWvYieldVault() {
    log("Creating syWFLOWvStrategy yield vault with 1.0 FLOW...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, flowVaultIdentifier, 1.0],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Retrieve the vault IDs
    let idsResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_ids.cdc",
        [userAccount.address]
    )
    Test.expect(idsResult, Test.beSucceeded())
    let ids = idsResult.returnValue! as! [UInt64]?
    Test.assert(ids != nil && ids!.length > 0, message: "Expected at least one yield vault")
    syWFLOWvYieldVaultID = ids![ids!.length - 1]
    log("Created syWFLOWv yield vault ID: ".concat(syWFLOWvYieldVaultID.toString()))

    // Verify initial balance
    let balResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(balResult, Test.beSucceeded())
    let balance = balResult.returnValue! as! UFix64?
    Test.assert(balance != nil, message: "Expected balance to be available")
    Test.assert(balance! > 0.0, message: "Expected positive balance after deposit")
    log("syWFLOWv vault balance: ".concat(balance!.toString()))
}

access(all) fun testDepositToSyWFLOWvYieldVault() {
    let balBeforeResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(balBeforeResult, Test.beSucceeded())
    let balanceBefore = balBeforeResult.returnValue! as! UFix64? ?? 0.0

    let depositAmount: UFix64 = 0.5
    log("Depositing 0.5 FLOW to syWFLOWv yield vault...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/deposit_to_yield_vault.cdc",
        [syWFLOWvYieldVaultID, depositAmount],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    let balResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(balResult, Test.beSucceeded())
    let balance = balResult.returnValue! as! UFix64?
    Test.assert(
        equalAmounts(a: balance!, b: balanceBefore + depositAmount, tolerance: 0.01),
        message: "Expected balance to increase by the deposit amount"
    )
    log("syWFLOWv vault balance after deposit: ".concat(balance!.toString()))
}

access(all) fun testWithdrawFromSyWFLOWvYieldVault() {
    let balBeforeResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(balBeforeResult, Test.beSucceeded())
    let balanceBefore = balBeforeResult.returnValue! as! UFix64? ?? 0.0

    let withdrawAmount: UFix64 = 0.3
    log("Withdrawing 0.3 FLOW from syWFLOWv yield vault...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/withdraw_from_yield_vault.cdc",
        [syWFLOWvYieldVaultID, withdrawAmount],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    let balResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(balResult, Test.beSucceeded())
    let balance = balResult.returnValue! as! UFix64?
    Test.assert(
        equalAmounts(a: balance!, b: balanceBefore - withdrawAmount, tolerance: 0.01),
        message: "Expected balance to decrease by the withdrawn amount"
    )
    log("syWFLOWv vault balance after withdrawal: ".concat(balance!.toString()))
}

access(all) fun testCloseSyWFLOWvYieldVault() {
    let vaultBalBeforeResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(vaultBalBeforeResult, Test.beSucceeded())
    let vaultBalanceBefore = vaultBalBeforeResult.returnValue! as! UFix64? ?? 0.0

    let flowBalBeforeResult = _executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [userAccount.address]
    )
    Test.expect(flowBalBeforeResult, Test.beSucceeded())
    let flowBalanceBefore = flowBalBeforeResult.returnValue! as! UFix64

    log("Closing syWFLOWv yield vault...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [syWFLOWvYieldVaultID],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    // Vault balance should now be nil (vault no longer exists)
    let vaultBalAfterResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, syWFLOWvYieldVaultID]
    )
    Test.expect(vaultBalAfterResult, Test.beSucceeded())
    Test.assert(vaultBalAfterResult.returnValue == nil, message: "Expected vault to no longer exist after close")

    // User's FLOW balance should have increased by approximately the vault's pre-close balance
    let flowBalAfterResult = _executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [userAccount.address]
    )
    Test.expect(flowBalAfterResult, Test.beSucceeded())
    let flowBalanceAfter = flowBalAfterResult.returnValue! as! UFix64
    Test.assert(
        equalAmounts(a: flowBalanceAfter, b: flowBalanceBefore + vaultBalanceBefore, tolerance: 0.01),
        message: "Expected user FLOW balance to increase by approximately the vault balance"
    )
    log("syWFLOWv yield vault closed successfully")
}
