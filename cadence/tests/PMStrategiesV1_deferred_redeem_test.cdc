#test_fork(network: "mainnet", height: nil)

import Test

/// Fork test for PMStrategiesV1 deferred redemption — validates request/query/cancel/recovery
/// against real mainnet EVM state (More Vaults Diamond vault with withdrawal queue).
///
/// Tests:
///   1. Create a syWFLOWv yield vault and deposit FLOW
///   2. Initialize PendingRedeemHandler
///   3. Request a deferred redemption (requestRedeem) with specific amount
///   4. Query pending state (getPendingRedeemInfo, getPendingRedeemNAVBalance)
///   5. Verify navBalance includes pending shares
///   6. View functions while pending (getAllPendingRedeemIDs, getScheduledClaim, getSchedulerBufferSeconds)
///   7. Negative: wrong COA on clearRedeemRequest, no-pending clearRedeemRequest
///   8. Cancel the deferred redemption (clearRedeemRequest), verify state cleared
///   9. Redeem all (nil amount) after cancel — exercises minimumAvailable() path, verifies lifecycle repeatability
///  10. Negative: claimRedeem with no pending redeem
///  11. claimRedeem before timelock — rejected by timestamp guard
///  12. EVM revert recovery: after timelock, redeem() reverts (stale oracle),
///      _evmRedeem returns nil, shares recovered to AutoBalancer
///  13. Re-request after recovery — verifies orphaned EVM request doesn't block a new requestRedeem
///
/// Mainnet addresses:
///   - Admin (FlowYieldVaults deployer): 0xb1d63873c3cc9f79
///   - syWFLOWv (More Vaults Diamond):   0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597
///   - Withdrawal timelock:              172800s (48h)

// --- Accounts ---

access(all) let adminAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let bandOracleAdmin = Test.getAccount(0x6801a6222ebf784a)
access(all) let userAccount = Test.getAccount(0x443472749ebdaac8)

// --- Constants ---

access(all) let syWFLOWvStrategyIdentifier = "A.b1d63873c3cc9f79.PMStrategiesV1.syWFLOWvStrategy"
access(all) let flowVaultIdentifier = "A.1654653399040a61.FlowToken.Vault"
access(all) let schedulingFee = 0.5

// --- Test State ---

access(all) var yieldVaultID: UInt64 = 0
access(all) var abBalanceBeforeRedeem = 0.0

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

    log("Refreshing Band FLOW/USD data for FlowALP...")
    var result = _executeTransactionFile(
        "transactions/band-oracle/refresh_flowalp_core_prices.cdc",
        [],
        [bandOracleAdmin]
    )
    Test.expect(result, Test.beSucceeded())

    // Grant beta access
    log("Granting beta access...")
    result = _executeTransactionFile(
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
    log("Created yield vault ID: \(yieldVaultID)")

    let balResult = _executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, yieldVaultID]
    )
    Test.expect(balResult, Test.beSucceeded())
    let balance = balResult.returnValue! as! UFix64?
    Test.assert(balance != nil && balance! > 0.0, message: "Expected positive balance after deposit")
    log("Vault balance: \(balance!)")
}

access(all) fun testNoPendingRedeemInitially() {
    let infoResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue == nil, message: "Expected no pending redeem initially")

    let navResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let nav = navResult.returnValue! as! UFix64
    Test.assert(nav == 0.0, message: "Expected zero pending NAV initially")
    log("No pending redeem initially — confirmed")
}

access(all) fun testRequestRedeem() {
    let navBefore = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance before requestRedeem: \(navBefore)")

    // Capture AutoBalancer share balance before redeem for end-to-end recovery verification
    abBalanceBeforeRedeem = (_executeScript(
        "../scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc",
        [yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("AutoBalancer share balance before requestRedeem: \(abBalanceBeforeRedeem)")

    log("Requesting deferred redeem for 1.0 FLOW worth of shares...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/request_redeem.cdc",
        [yieldVaultID, 1.0 as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("requestRedeem succeeded")

    // Verify pending state exists
    let infoResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue != nil, message: "Expected pending redeem info after request")
    log("Pending redeem info confirmed present")

    // Verify pending NAV > 0
    let navResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let pendingNAV = navResult.returnValue! as! UFix64
    Test.assert(pendingNAV > 0.0, message: "Expected positive pending NAV")
    log("Pending NAV: \(pendingNAV)")

    // NAV balance (via navBalance()) should include pending shares
    let navAfter = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance after requestRedeem (should include pending): \(navAfter)")
    Test.assert(
        equalAmounts(a: navAfter, b: navBefore, tolerance: 0.05),
        message: "NAV balance should still include pending shares"
    )

    // Available balance should be reduced (shares moved out of AutoBalancer)
    let availAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("Available balance after requestRedeem: \(availAfter)")
    Test.assert(availAfter < navBefore, message: "Available balance should drop after requestRedeem")
}

access(all) fun testDuplicateRequestRedeemFails() {
    log("Attempting duplicate requestRedeem (should fail)...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/request_redeem.cdc",
        [yieldVaultID, 0.5 as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beFailed())
    log("Duplicate requestRedeem correctly rejected")
}

access(all) fun testViewFunctionsWhilePending() {
    // getAllPendingRedeemIDs — should contain our yieldVaultID
    let idsResult = _executeScript(
        "scripts/pm-strategies/get_all_pending_redeem_ids.cdc",
        []
    )
    Test.expect(idsResult, Test.beSucceeded())
    let ids = idsResult.returnValue! as! [UInt64]
    Test.assert(ids.contains(yieldVaultID), message: "Pending IDs should contain our yieldVaultID")
    log("getAllPendingRedeemIDs contains \(yieldVaultID)")

    // getScheduledClaim — should return a future timestamp
    let tsResult = _executeScript(
        "scripts/pm-strategies/get_scheduled_claim_timestamp.cdc",
        [yieldVaultID]
    )
    Test.expect(tsResult, Test.beSucceeded())
    let ts = tsResult.returnValue! as! UFix64?
    Test.assert(ts != nil, message: "Expected scheduled claim timestamp")
    Test.assert(ts! > getCurrentBlock().timestamp, message: "Scheduled timestamp should be in the future")
    log("getScheduledClaim timestamp: \(ts!)")

    // getSchedulerBufferSeconds — should be non-nil
    let bufResult = _executeScript(
        "scripts/pm-strategies/get_scheduler_buffer_seconds.cdc",
        []
    )
    Test.expect(bufResult, Test.beSucceeded())
    let buf = bufResult.returnValue! as! UFix64?
    Test.assert(buf != nil, message: "Expected scheduler buffer seconds")
    log("getSchedulerBufferSeconds: \(buf!)")
}

access(all) fun testClearRedeemRequestWrongCOAFails() {
    log("Attempting clearRedeemRequest with admin COA (should fail)...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/clear_redeem_request.cdc",
        [yieldVaultID],
        [adminAccount]
    )
    Test.expect(result, Test.beFailed())
    log("clearRedeemRequest with wrong COA correctly rejected")
}

access(all) fun testClearRedeemRequest() {
    let navBefore = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance before clearRedeemRequest: \(navBefore)")

    log("Clearing redeem request...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/clear_redeem_request.cdc",
        [yieldVaultID],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("clearRedeemRequest succeeded")

    // Pending state should be cleared
    let infoResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue == nil, message: "Expected no pending redeem after clear")

    let navResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    )
    Test.expect(navResult, Test.beSucceeded())
    let pendingNAV = navResult.returnValue! as! UFix64
    Test.assert(pendingNAV == 0.0, message: "Expected zero pending NAV after clear")

    // NAV balance should be preserved (shares returned to AutoBalancer)
    let navAfter = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV balance after clearRedeemRequest: \(navAfter)")
    Test.assert(
        equalAmounts(a: navAfter, b: navBefore, tolerance: 0.05),
        message: "NAV balance should be preserved after clearing redeem request"
    )
    log("Shares restored to AutoBalancer — confirmed")

    // View functions should reflect cleared state
    let idsResult = _executeScript(
        "scripts/pm-strategies/get_all_pending_redeem_ids.cdc",
        []
    )
    Test.expect(idsResult, Test.beSucceeded())
    let clearedIds = idsResult.returnValue! as! [UInt64]
    Test.assert(!clearedIds.contains(yieldVaultID), message: "Pending IDs should not contain our yieldVaultID after clear")

    let tsResult = _executeScript(
        "scripts/pm-strategies/get_scheduled_claim_timestamp.cdc",
        [yieldVaultID]
    )
    Test.expect(tsResult, Test.beSucceeded())
    Test.assert(tsResult.returnValue == nil, message: "Expected no scheduled claim after clear")
    log("View functions confirm cleared state")
}

access(all) fun testClearRedeemRequestNoPendingFails() {
    log("Attempting clearRedeemRequest with no pending redeem (should fail)...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/clear_redeem_request.cdc",
        [yieldVaultID],
        [userAccount]
    )
    Test.expect(result, Test.beFailed())
    log("clearRedeemRequest with no pending redeem correctly rejected")
}

access(all) fun testRedeemAllAfterCancel() {
    let navBefore = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV before redeem-all: \(navBefore)")

    // Request redeem with nil amount (redeem all shares)
    log("Requesting deferred redeem for ALL shares (nil amount)...")
    var result = _executeTransactionFile(
        "transactions/pm-strategies/request_redeem.cdc",
        [yieldVaultID, nil as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("requestRedeem (all) succeeded")

    // Available balance should be ~0 (all shares moved to pending)
    let availAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_yield_vault_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    Test.assert(
        equalAmounts(a: availAfter, b: 0.0, tolerance: 0.01),
        message: "Available balance should be ~0 after redeem-all"
    )
    log("Available balance after redeem-all: \(availAfter)")

    // Pending NAV should approximate the full vault NAV
    let pendingNAV = (_executeScript(
        "scripts/pm-strategies/get_pending_redeem_nav_balance.cdc",
        [yieldVaultID]
    ).returnValue! as! UFix64)
    Test.assert(pendingNAV > 0.0, message: "Expected positive pending NAV for redeem-all")
    Test.assert(
        equalAmounts(a: pendingNAV, b: navBefore, tolerance: 0.05),
        message: "Pending NAV should approximate full vault NAV"
    )
    log("Pending NAV (all): \(pendingNAV)")

    // Cancel to leave clean state
    log("Cancelling re-request...")
    result = _executeTransactionFile(
        "transactions/pm-strategies/clear_redeem_request.cdc",
        [yieldVaultID],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())

    let idsResult = _executeScript(
        "scripts/pm-strategies/get_all_pending_redeem_ids.cdc",
        []
    )
    Test.expect(idsResult, Test.beSucceeded())
    let clearedIds = idsResult.returnValue! as! [UInt64]
    Test.assert(!clearedIds.contains(yieldVaultID), message: "Pending IDs should not contain our yieldVaultID after re-cancel")
    log("Re-request -> cancel lifecycle complete")
}

access(all) fun testClaimRedeemNoPendingFails() {
    log("Attempting claimRedeem with no pending redeem (should fail)...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/claim_redeem.cdc",
        [yieldVaultID],
        []
    )
    Test.expect(result, Test.beFailed())
    log("claimRedeem with no pending correctly rejected")
}

access(all) fun testClaimRedeemBeforeTimelockFails() {
    let navBefore = (_executeScript(
        "scripts/pm-strategies/get_yield_vault_nav_balance.cdc",
        [userAccount.address, yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("NAV before timelock-guard test: \(navBefore)")

    // Request a deferred redeem
    log("Requesting deferred redeem for 1.0 FLOW worth of shares...")
    var result = _executeTransactionFile(
        "transactions/pm-strategies/request_redeem.cdc",
        [yieldVaultID, 1.0 as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("requestRedeem succeeded")

    // Call claimRedeem immediately — should be rejected by timestamp guard
    log("Calling claimRedeem before timelock (should be rejected)...")
    result = _executeTransactionFile(
        "transactions/pm-strategies/claim_redeem.cdc",
        [yieldVaultID],
        []
    )
    Test.expect(result, Test.beFailed())
    log("claimRedeem before timelock correctly rejected")

    // Pending state should still exist (nothing changed)
    let infoResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue != nil, message: "Pending redeem should still exist after rejected claim")
    log("Pending state preserved after rejected early claim")
}

access(all) fun testEVMRedeemRevertTriggersRecovery() {
    // Pending redeem exists from testClaimRedeemBeforeTimelockFails.
    let infoBefore = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoBefore, Test.beSucceeded())
    Test.assert(infoBefore.returnValue != nil, message: "Expected pending redeem before moveTime")

    let abBefore = (_executeScript(
        "../scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc",
        [yieldVaultID]
    ).returnValue! as! UFix64?)!
    let userFlowBefore = getAccount(userAccount.address).balance

    // moveTime advances past the scheduled timestamp (timelock + schedulerBuffer).
    // The 48h time jump makes EVM oracle data stale → redeem() reverts →
    // _evmRedeem returns nil → recovery pulls shares back to AutoBalancer.
    Test.moveTime(by: 172831.0)

    // Pending state cleared
    let infoAfter = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoAfter, Test.beSucceeded())
    Test.assert(infoAfter.returnValue == nil, message: "Expected pending redeem cleared after recovery")

    let idsResult = _executeScript(
        "scripts/pm-strategies/get_all_pending_redeem_ids.cdc",
        []
    )
    Test.expect(idsResult, Test.beSucceeded())
    let ids = idsResult.returnValue! as! [UInt64]
    Test.assert(ids.length == 0, message: "Expected no pending redeem IDs after recovery")

    // Shares recovered to AutoBalancer
    let abAfter = (_executeScript(
        "../scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc",
        [yieldVaultID]
    ).returnValue! as! UFix64?)!
    Test.assert(abAfter > abBefore, message: "Expected AutoBalancer increase from recovered shares")
    log("Shares recovered to AutoBalancer (delta: \(abAfter - abBefore))")

    // User received no FLOW (recovery, not happy path)
    let userFlowAfter = getAccount(userAccount.address).balance
    Test.assert(
        userFlowAfter == userFlowBefore,
        message: "Expected no FLOW change for user during recovery"
    )

    // Claim outcome should be "failed" (recovery, not success)
    let outcomeResult = _executeScript(
        "scripts/pm-strategies/get_claim_outcome.cdc",
        [yieldVaultID]
    )
    Test.expect(outcomeResult, Test.beSucceeded())
    let outcome = outcomeResult.returnValue! as! String?
    Test.assert(outcome == "failed", message: "Expected claim outcome 'failed' after recovery")
    log("Claim outcome after recovery: \(outcome!)")
}

access(all) fun testRequestRedeemAfterRecovery() {
    // After recovery, Cadence state is clean but the EVM vault may still have
    // an orphaned withdrawal request from the previous requestRedeem.
    // This test verifies a new requestRedeem succeeds despite that.
    //
    // NOTE: EVM view calls (navBalance, convertToAssets) are unreliable after
    // the 48h moveTime — oracle data is stale. Use Cadence-side AutoBalancer
    // balance and nil-amount redeem (skips convertToShares EVM call).

    let abBalance = (_executeScript(
        "../scripts/flow-yield-vaults/get_auto_balancer_balance_by_id.cdc",
        [yieldVaultID]
    ).returnValue! as! UFix64?)!
    log("AutoBalancer share balance after recovery: \(abBalance)")
    Test.assert(abBalance > 0.0, message: "Expected positive AutoBalancer balance from recovered shares")

    // Use nil amount to redeem all shares — avoids convertToShares EVM call
    log("Requesting deferred redeem (all) after recovery...")
    let result = _executeTransactionFile(
        "transactions/pm-strategies/request_redeem.cdc",
        [yieldVaultID, nil as UFix64?, schedulingFee],
        [userAccount]
    )
    Test.expect(result, Test.beSucceeded())
    log("requestRedeem after recovery succeeded — orphaned EVM request did not block")

    // Verify pending state exists
    let infoResult = _executeScript(
        "scripts/pm-strategies/get_pending_redeem_info.cdc",
        [yieldVaultID]
    )
    Test.expect(infoResult, Test.beSucceeded())
    Test.assert(infoResult.returnValue != nil, message: "Expected pending redeem after re-request")

    // Claim outcome should be cleared on new requestRedeem
    let outcomeResult = _executeScript(
        "scripts/pm-strategies/get_claim_outcome.cdc",
        [yieldVaultID]
    )
    Test.expect(outcomeResult, Test.beSucceeded())
    Test.assert(outcomeResult.returnValue == nil, message: "Expected nil claim outcome after re-request")
    log("Re-request after recovery lifecycle complete")
}
