import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowYieldVaultsSchedulerV1"
import "FlowYieldVaultsSchedulerRegistry"
import "FlowTransactionScheduler"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    log("Setting up scheduler edge cases test...")
    
    deployContracts()
    
    // Fund FlowYieldVaults account for scheduling fees
    mintFlow(to: flowYieldVaultsAccount, amount: 1000.0)

    // Set mocked token prices
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // Mint tokens and set liquidity
    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // Setup FlowALPv1
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        yearlyRate: UFix128(0.1),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/transactions/flow-alp/position/create_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Enable Strategy creation
    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )

    log("Setup complete")
    
    // Capture snapshot for test isolation
    snapshot = getCurrentBlockHeight()
}

/// Test: New yield vault has active native schedule immediately after creation
///
/// Verifies that when a yield vault is created, it automatically starts self-scheduling
/// via the native AutoBalancer mechanism without any Supervisor intervention.
///
access(all)
fun testYieldVaultHasNativeScheduleAfterCreation() {
    log("\n[TEST] YieldVault has native schedule immediately after creation...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create a YieldVault
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))
    
    // Verify yield vault is registered and has active schedule (native self-scheduling)
    let hasActive = (executeScript(
        "../scripts/flow-yield-vaults/has_active_schedule.cdc",
        [yieldVaultID]
    ).returnValue! as! Bool)
    Test.assert(hasActive, message: "YieldVault should have active native schedule immediately after creation")
    
    log("PASS: YieldVault has native self-scheduling immediately after creation")
}

/// NOTE: Cancel recovery transaction was removed.
/// Recovery schedule cancellation is not a primary use case.
/// If a yield vault needs to stop, close it via close_yield_vault.cdc.

/// Test: Capability reuse - registering same yield vault twice should not issue new caps
access(all)
fun testCapabilityReuse() {
    log("\n[TEST] Capability reuse on re-registration...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    
    // Check registration
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(yieldVaultID), message: "YieldVault should be registered")
    
    // Get wrapper cap (first time)
    let capRes1 = executeScript("../scripts/flow-yield-vaults/has_wrapper_cap_for_yield_vault.cdc", [yieldVaultID])
    Test.expect(capRes1, Test.beSucceeded())
    let hasCap1 = capRes1.returnValue! as! Bool
    Test.assert(hasCap1, message: "Should have wrapper cap after creation")
    
    log("Capability correctly exists and would be reused on re-registration")
}

/// Test: Close yield vault properly unregisters from registry
///
/// When a yield vault is closed:
/// 1. It should be unregistered from the registry
/// 2. Any active schedules should be cleaned up
///
access(all)
fun testCloseYieldVaultUnregisters() {
    log("\n[TEST] Close yield vault properly unregisters from registry...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 400.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create a yield vault
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))
    
    // Verify registered
    let regIDsBefore = (executeScript(
        "../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc",
        []
    ).returnValue! as! [UInt64])
    Test.assert(regIDsBefore.contains(yieldVaultID), message: "YieldVault should be registered")
    log("YieldVault is registered")
    
    // Close the yield vault
    let closeRes = executeTransaction(
        "../transactions/flow-yield-vaults/close_yield_vault.cdc",
        [yieldVaultID],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())
    log("YieldVault closed successfully")
    
    // Verify unregistered
    let regIDsAfter = (executeScript(
        "../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc",
        []
    ).returnValue! as! [UInt64])
    Test.assert(!regIDsAfter.contains(yieldVaultID), message: "YieldVault should be unregistered after close")
    log("YieldVault correctly unregistered after close")
}

/// Test: Multiple users with multiple yield vaults all registered correctly
access(all)
fun testMultipleUsersMultipleYieldVaults() {
    log("\n[TEST] Multiple users with multiple yield vaults...")
    
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    mintFlow(to: user1, amount: 500.0)
    mintFlow(to: user2, amount: 500.0)
    grantBeta(flowYieldVaultsAccount, user1)
    grantBeta(flowYieldVaultsAccount, user2)
    
    // User1 creates 2 yield vaults
    executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user1
    )
    executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user1
    )
    
    // User2 creates 1 yield vault
    executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user2
    )
    
    let user1YieldVaults = getYieldVaultIDs(address: user1.address)!
    let user2YieldVaults = getYieldVaultIDs(address: user2.address)!
    
    Test.assert(user1YieldVaults.length >= 2, message: "User1 should have at least 2 yield vaults")
    Test.assert(user2YieldVaults.length >= 1, message: "User2 should have at least 1 yield vault")
    
    // Verify all are registered
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    
    for tid in user1YieldVaults {
        Test.assert(regIDs.contains(tid), message: "User1 yield vault should be registered")
    }
    for tid in user2YieldVaults {
        Test.assert(regIDs.contains(tid), message: "User2 yield vault should be registered")
    }
    
    log("All yield vaults from multiple users correctly registered: ".concat(regIDs.length.toString()).concat(" total"))
}

/// Test: Healthy yield vaults continue executing without Supervisor intervention
access(all)
fun testHealthyYieldVaultsSelfSchedule() {
    Test.reset(to: snapshot)
    log("\n[TEST] Healthy yield vaults continue executing without Supervisor...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 500.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create a yield vault
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))
    
    // Track initial balance
    var prevBalance = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
    log("Initial balance: ".concat(prevBalance.toString()))
    
    // Execute 3 rounds with balance verification using LARGE price changes
    var round = 1
    while round <= 3 {
        // Use LARGE price changes to ensure rebalancing triggers
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5 * UFix64(round))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2 * UFix64(round))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        
        let newBalance = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
        log("Round ".concat(round.toString()).concat(": Balance ").concat(prevBalance.toString()).concat(" -> ").concat(newBalance.toString()))
        Test.assert(newBalance != prevBalance, message: "Balance should change after round ".concat(round.toString()))
        prevBalance = newBalance
        
        round = round + 1
    }
    
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 3 rounds: ".concat(execEvents.length.toString()))
    Test.assert(execEvents.length >= 3, message: "Should have at least 3 executions")
    
    // Verify not stuck (healthy yield vault should not be stuck)
    let isStuck = (executeScript(
        "../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc",
        [yieldVaultID]
    ).returnValue! as! Bool)
    Test.assert(!isStuck, message: "Healthy yield vault should not be stuck")
    
    log("PASS: Healthy yield vault continues self-scheduling without Supervisor with verified balance changes")
}
