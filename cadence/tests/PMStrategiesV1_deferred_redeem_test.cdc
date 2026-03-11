#test_fork(network: "mainnet", height: nil)

import Test

/// Fork test for PMStrategiesV1 deferred redemption — validates request/query/cancel
/// against real mainnet EVM state (More Vaults Diamond vault with withdrawal queue).
///
/// Tests:
///   1. Create a syWFLOWv yield vault and deposit FLOW
///   2. Initialize PendingRedeemHandler
///   3. Request a deferred redemption (requestRedeem)
///   4. Query pending state (getPendingRedeemInfo, getPendingRedeemNAVBalance)
///   5. Verify navBalance includes pending shares
///   6. Cancel the deferred redemption (clearRedeemRequest)
///   7. Verify shares restored and pending state cleared
///
/// claimRedeem is not fork-testable: moveTime() advances block.timestamp past
/// the 48h timelock but EVM oracle/yield state stays frozen, causing redeem() to
/// revert on stale-data checks. Cadence-side scheduler logic verified separately.
///
/// Mainnet addresses:
///   - Admin (FlowYieldVaults deployer): 0xb1d63873c3cc9f79
///   - syWFLOWv (More Vaults Diamond):   0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597
///   - Withdrawal timelock:              172800s (48h)

// --- Accounts ---

access(all) let adminAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let userAccount = Test.getAccount(0x443472749ebdaac8)

// --- Constants ---

access(all) let syWFLOWvStrategyIdentifier = "A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy"
access(all) let flowVaultIdentifier = "A.1654653399040a61.FlowToken.Vault"
access(all) let schedulingFee: UFix64 = 0.5

// --- Test State ---

access(all) var yieldVaultID: UInt64 = 0

/* --- Helpers --- */

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
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
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
    log("==== PMStrategiesV1 Deferred Redeem Fork Test Setup ====")

    // Deploy FlowActions dependencies (latest local code)
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

    // Deploy updated FlowYieldVaults platform contracts
    log("Deploying FlowYieldVaults...")
    err = Test.deployContract(
        name: "FlowYieldVaults",
        path: "../../cadence/contracts/FlowYieldVaults.cdc",
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

    // Grant beta access
    log("Granting beta access...")
    var result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/grant_beta.cdc",
        [],
        [adminAccount, userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    log("Initializing PendingRedeemHandler...")
    result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/admin/init_pending_redeem_handler.cdc",
        [],
        []
    )
    Test.expect(result, Test.beSucceeded())

    // Ensure user has a COA
    log("Setting up user COA...")
    let setupCOATxCode = "import \"EVM\"\ntransaction() {\n    prepare(signer: auth(SaveValue, StorageCapabilities, PublishCapability) &Account) {\n        if signer.storage.type(at: /storage/evm) == nil {\n            signer.storage.save(<-EVM.createCadenceOwnedAccount(), to: /storage/evm)\n            let cap = signer.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(/storage/evm)\n            signer.capabilities.publish(cap, at: /public/evm)\n        }\n    }\n}"
    let setupCOATx = Test.Transaction(
        code: setupCOATxCode,
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: []
    )
    result = Test.executeTransaction(setupCOATx)
    Test.expect(result, Test.beSucceeded())

    log("==== Setup Complete ====")
}

/* --- Tests --- */

access(all) fun testCreateYieldVaultForDeferredRedeem() {
    log("Creating syWFLOWv yield vault with 2.0 FLOW...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [syWFLOWvStrategyIdentifier, flowVaultIdentifier, 2.0],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    let idsResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_ids.cdc",
        [userAccount.address]
    )
    Test.expect(idsResult, Test.beSucceeded())
    let ids = idsResult.returnValue! as! [UInt64]?
    Test.assert(ids != nil && ids!.length > 0, message: "Expected at least one yield vault")
    yieldVaultID = ids![ids!.length - 1]
    log("Created yield vault ID: ".concat(yieldVaultID.toString()))

    let balResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, yieldVaultID]
    )
    Test.expect(balResult, Test.beSucceeded())
    let balance = balResult.returnValue! as! UFix64?
    Test.assert(balance != nil && balance! > 0.0, message: "Expected positive balance after deposit")
    log("Vault balance: ".concat(balance!.toString()))
}

access(all) fun testNoPendingRedeemInitially() {
    let infoResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue == nil, message: "Expected no pending redeem initially")

    let navResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let nav = navResult.returnValue! as! UFix64
    Test.assert(nav == 0.0, message: "Expected zero pending NAV initially")
    log("No pending redeem initially — confirmed")
}

access(all) fun testRequestRedeem() {
    let navBefore = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance before requestRedeem: ".concat(navBefore.toString()))

    log("Requesting deferred redeem for 1.0 FLOW worth of shares...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/request_redeem.cdc",
        [yieldVaultID, 1.0 as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("requestRedeem succeeded")

    // Verify pending state exists
    let infoResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue != nil, message: "Expected pending redeem info after request")
    log("Pending redeem info confirmed present")

    // Verify pending NAV > 0
    let navResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let pendingNAV = navResult.returnValue! as! UFix64
    Test.assert(pendingNAV > 0.0, message: "Expected positive pending NAV")
    log("Pending NAV: ".concat(pendingNAV.toString()))

    // NAV balance (via navBalance()) should include pending shares
    let navAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance after requestRedeem (should include pending): ".concat(navAfter.toString()))
    Test.assert(
        equalAmounts(a: navAfter, b: navBefore, tolerance: 0.05),
        message: "NAV balance should still include pending shares"
    )

    // Available balance should be reduced (shares moved out of AutoBalancer)
    let availAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("Available balance after requestRedeem: ".concat(availAfter.toString()))
    Test.assert(availAfter < navBefore, message: "Available balance should drop after requestRedeem")
}

access(all) fun testDuplicateRequestRedeemFails() {
    log("Attempting duplicate requestRedeem (should fail)...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/request_redeem.cdc",
        [yieldVaultID, 0.5 as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beFailed())
    log("Duplicate requestRedeem correctly rejected")
}

access(all) fun testClearRedeemRequest() {
    let navBefore = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance before clearRedeemRequest: ".concat(navBefore.toString()))

    log("Clearing redeem request...")
    let result = _executeTransactionFile(
        "../transactions/flow-yield-vaults/clear_redeem_request.cdc",
        [yieldVaultID],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("clearRedeemRequest succeeded")

    // Pending state should be cleared
    let infoResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue == nil, message: "Expected no pending redeem after clear")

    let navResult = _executeScript(
        "../scripts/flow-yield-vaults/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let pendingNAV = navResult.returnValue! as! UFix64
    Test.assert(pendingNAV == 0.0, message: "Expected zero pending NAV after clear")

    // NAV balance should be preserved (shares returned to AutoBalancer)
    let navAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance after clearRedeemRequest: ".concat(navAfter.toString()))
    Test.assert(
        equalAmounts(a: navAfter, b: navBefore, tolerance: 0.05),
        message: "NAV balance should be preserved after clearing redeem request"
    )
    log("Shares restored to AutoBalancer — confirmed")
}
