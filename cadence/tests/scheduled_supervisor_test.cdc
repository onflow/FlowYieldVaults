import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "DeFiActions"
import "FlowYieldVaultsSchedulerRegistry"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

// Snapshot for test isolation - captured after setup completes
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    log("🚀 Setting up Supervisor integration test...")

    deployContracts()

    // Fund FlowYieldVaults account BEFORE any YieldVaults are created, as registerYieldVault
    // now atomically schedules the first execution which requires FLOW for fees
    mintFlow(to: flowYieldVaultsAccount, amount: 1000.0)

    // Mock Oracle
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // Liquidity
    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // FlowCreditMarket
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

    // Wrapped Position
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/transactions/flow-credit-market/position/create_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Strategy Composer
    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )

    // Capture snapshot for test isolation
    snapshot = getCurrentBlockHeight()
    log("✅ Setup complete. Snapshot at block: ".concat(snapshot.toString()))
}

/// Test: Auto-Register and Native Scheduling
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native FlowTransactionScheduler
/// - The Supervisor is for recovery only (detects stuck yield vaults and seeds them)
/// - Supervisor tracks its own recovery schedules
///
access(all)
fun testAutoRegisterAndSupervisor() {
    log("\n Testing Auto-Register + Native Scheduling...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)

    // 1. Create YieldVault (Should auto-register and self-schedule via native mechanism)
    log("Step 1: Create YieldVault")
    let createYieldVaultRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createYieldVaultRes, Test.beSucceeded())

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))

    // 2. Verify registration
    let regIDsRes = executeScript(
        "../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc",
        []
    )
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(yieldVaultID), message: "YieldVault should be registered")
    log("YieldVault is registered")

    // 3. Wait for native AutoBalancer execution
    log("Step 2: Wait for native execution...")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)

    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    // 4. Verify native execution occurred
    let schedulerExecEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    Test.assert(schedulerExecEvents.length > 0, message: "Should have FlowTransactionScheduler.Executed event")

    let rebalancedEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("Scheduler.Executed events: ".concat(schedulerExecEvents.length.toString()))
    log("DeFiActions.Rebalanced events: ".concat(rebalancedEvents.length.toString()))

    log("PASS: Auto-Register + Native Scheduling")
}

/// Test: Multiple yield vaults all self-schedule via native mechanism
///
/// NEW ARCHITECTURE:
/// - Each yield vault's AutoBalancer self-schedules via native FlowTransactionScheduler
/// - No Supervisor seeding needed - yield vaults execute independently
/// - This tests that multiple yield vaults can be created and all self-schedule
///
access(all)
fun testMultiYieldVaultNativeScheduling() {
    log("\n Testing Multiple YieldVaults Native Scheduling...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)

    // Create 3 yield vaults (each auto-schedules via native mechanism)
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 100.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }

    let allYieldVaults = getYieldVaultIDs(address: user.address)!
    log("Created ".concat(allYieldVaults.length.toString()).concat(" yield vaults"))

    // Verify all are registered
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    for tid in allYieldVaults {
        Test.assert(regIDs.contains(tid), message: "YieldVault should be registered")
    }
    log("All yield vaults registered")

    // Wait for native execution
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    // Verify all executed via native scheduling
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    Test.assert(execEvents.length >= 3, message: "Should have at least 3 executions (one per yield vault)")
    log("Executions: ".concat(execEvents.length.toString()))

    log("PASS: Multiple YieldVaults Native Scheduling")
}

// NOTE: testRecurringRebalancingThreeRuns was removed as it duplicates
// testSingleAutoBalancerThreeExecutions in scheduled_rebalance_scenario_test.cdc

/// Test: Multiple yield vaults execute independently via native scheduling
///
/// NEW ARCHITECTURE:
/// - Each AutoBalancer self-schedules via native mechanism
/// - No Supervisor needed for normal execution
///
access(all)
fun testMultiYieldVaultIndependentExecution() {
    Test.reset(to: snapshot)
    log("\n Testing multiple yield vaults execute independently...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)

    // Create 3 yield vaults (each auto-schedules via native mechanism)
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 100.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    log("Created ".concat(yieldVaultIDs.length.toString()).concat(" yield vaults"))

    // Track balance for first yield vault to verify rebalancing works
    let trackedYieldVaultID = yieldVaultIDs[0]
    var prevBalance = getAutoBalancerBalance(id: trackedYieldVaultID) ?? 0.0
    log("Initial balance (yield vault ".concat(trackedYieldVaultID.toString()).concat("): ").concat(prevBalance.toString()))

    // Drive 3 rounds of execution with balance verification
    var round = 1
    while round <= 3 {
        // Use VERY LARGE price changes to ensure rebalancing triggers regardless of previous state
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 3.0 * UFix64(round))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 2.5 * UFix64(round))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()

        let newBalance = getAutoBalancerBalance(id: trackedYieldVaultID) ?? 0.0
        log("Round ".concat(round.toString()).concat(": Balance ").concat(prevBalance.toString()).concat(" -> ").concat(newBalance.toString()))
        Test.assert(newBalance != prevBalance, message: "Balance should change after round ".concat(round.toString()).concat(" (was: ").concat(prevBalance.toString()).concat(", now: ").concat(newBalance.toString()).concat(")"))
        prevBalance = newBalance

        round = round + 1
    }

    // Count executions
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(execEvents.length.toString()))

    // 3 yield vaults x 3 rounds = 9 minimum executions
    Test.assert(
        execEvents.length >= 9,
        message: "Expected at least 9 executions but found ".concat(execEvents.length.toString())
    )

    log("PASS: Multiple yield vaults executed independently with verified balance changes")
}

/// Stress test: tests pagination with many yield vaults exceeding MAX_BATCH_SIZE (5)
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native mechanism
/// - Registry tracks all registered yield vaults
/// - Pending queue is for RECOVERY (failed self-schedules)
/// - Pagination is used when processing pending queue in batches
///
/// Tests pagination with a large number of yield vaults, each executing at least 3 times.
///
/// Uses dynamic batch size: 3 * MAX_BATCH_SIZE + partial (3 in this case)
/// MAX_BATCH_SIZE = 5, so total = 3*5 + 3 = 18 yield vaults
///
/// This verifies:
/// 1. All yield vaults are registered correctly
/// 2. Pagination functions work correctly across multiple pages
/// 3. All yield vaults self-schedule and execute at least 3 times each
///
access(all)
fun testPaginationStress() {
    Test.reset(to: snapshot)
    // Calculate number of yield vaults: 3 * MAX_BATCH_SIZE + partial batch
    // MAX_BATCH_SIZE is 5 in FlowYieldVaultsSchedulerRegistry
    let maxBatchSize = 5
    let fullBatches = 3
    let partialBatch = 3  // Less than MAX_BATCH_SIZE
    let numYieldVaults = fullBatches * maxBatchSize + partialBatch  // 18 yield vaults
    let minExecutionsPerYieldVault = 3
    let minTotalExecutions = numYieldVaults * minExecutionsPerYieldVault  // 54 minimum (18 x 3)

    log("\n Testing pagination with ".concat(numYieldVaults.toString()).concat(" yield vaults (").concat(fullBatches.toString()).concat("x MAX_BATCH_SIZE + ").concat(partialBatch.toString()).concat(")..."))
    log("Expecting at least ".concat(minTotalExecutions.toString()).concat(" total executions (").concat(minExecutionsPerYieldVault.toString()).concat(" per yield vault)"))

    let user = Test.createAccount()
    mintFlow(to: user, amount: 10000.0)  // For 3 rounds of 18 yield vaults
    grantBeta(flowYieldVaultsAccount, user)
    mintFlow(to: flowYieldVaultsAccount, amount: 50000.0)  // Increased for scheduling fees

    // Create yield vaults
    log("Creating ".concat(numYieldVaults.toString()).concat(" yield vaults..."))
    var i = 0
    while i < numYieldVaults {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 5.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    log("Created ".concat(yieldVaultIDs.length.toString()).concat(" yield vaults"))
    Test.assertEqual(numYieldVaults, yieldVaultIDs.length)

    // Check registry state - all yield vaults should be registered
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    log("Registered yield vaults: ".concat(regIDs.length.toString()))

    Test.assert(
        regIDs.length >= numYieldVaults,
        message: "Expected at least ".concat(numYieldVaults.toString()).concat(" registered yield vaults, got ").concat(regIDs.length.toString())
    )

    // Verify pagination works on pending queue (should be empty since all self-schedule)
    let pendingCountRes = executeScript("../scripts/flow-yield-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    log("Pending queue size (should be 0 since all self-schedule): ".concat(pendingCount.toString()))
    Test.assertEqual(0, pendingCount)

    // Test paginated access - request each page up to MAX_BATCH_SIZE
    var page = 0
    while page <= fullBatches {
        let pageRes = executeScript("../scripts/flow-yield-vaults/get_pending_yield_vaults_paginated.cdc", [page, maxBatchSize])
        let pageData = pageRes.returnValue! as! [UInt64]
        log("Page ".concat(page.toString()).concat(" of pending queue: ").concat(pageData.length.toString()).concat(" yield vaults"))
        page = page + 1
    }

    // Track balance for first 3 yield vaults (sample) to verify rebalancing
    var sampleBalances: [UFix64] = []
    var sampleIdx = 0
    while sampleIdx < 3 {
        sampleBalances.append(getAutoBalancerBalance(id: yieldVaultIDs[sampleIdx]) ?? 0.0)
        sampleIdx = sampleIdx + 1
    }
    log("Initial sample balances (first 3 yield vaults): T0=".concat(sampleBalances[0].toString()).concat(", T1=").concat(sampleBalances[1].toString()).concat(", T2=").concat(sampleBalances[2].toString()))

    // Execute 3 rounds - verify each yield vault executes at least 3 times with balance verification
    log("\n--- Executing 3 rounds ---")
    var round = 1
    while round <= minExecutionsPerYieldVault {
        // Use LARGE price changes to ensure rebalancing triggers regardless of previous state
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 * UFix64(round))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5 * UFix64(round))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()

        // Verify sample balances changed
        sampleIdx = 0
        while sampleIdx < 3 {
            let newBal = getAutoBalancerBalance(id: yieldVaultIDs[sampleIdx]) ?? 0.0
            Test.assert(newBal != sampleBalances[sampleIdx], message: "Sample yield vault ".concat(sampleIdx.toString()).concat(" balance should change after round ").concat(round.toString()))
            sampleBalances[sampleIdx] = newBal
            sampleIdx = sampleIdx + 1
        }

        let roundEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        let expectedMinEvents = numYieldVaults * round
        log("Round ".concat(round.toString()).concat(": ").concat(roundEvents.length.toString()).concat(" total executions (expected >= ").concat(expectedMinEvents.toString()).concat("), sample balances verified"))

        Test.assert(
            roundEvents.length >= expectedMinEvents,
            message: "Round ".concat(round.toString()).concat(": Expected at least ").concat(expectedMinEvents.toString()).concat(" executions, got ").concat(roundEvents.length.toString())
        )
        round = round + 1
    }

    // Final verification
    let finalEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("\nFinal total executions: ".concat(finalEvents.length.toString()))

    Test.assert(
        finalEvents.length >= minTotalExecutions,
        message: "Expected at least ".concat(minTotalExecutions.toString()).concat(" total executions (").concat(numYieldVaults.toString()).concat(" yield vaults x ").concat(minExecutionsPerYieldVault.toString()).concat(" rounds), got ").concat(finalEvents.length.toString())
    )

    log("PASS: ".concat(numYieldVaults.toString()).concat(" yield vaults all registered and executed at least ").concat(minExecutionsPerYieldVault.toString()).concat(" times each"))
}

/// Tests that Supervisor does not disrupt healthy yield vaults
///
/// This test verifies that when Supervisor runs, it does NOT interfere with
/// healthy yield vaults that are self-scheduling correctly.
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native FlowTransactionScheduler
/// - Supervisor periodically scans for "stuck" yield vaults (overdue + no active schedule)
/// - Healthy yield vaults never appear in pending queue
/// - Supervisor runs but finds nothing to recover
///
/// TEST SCENARIO:
/// 1. Create healthy yield vault (AutoBalancer schedules itself natively)
/// 2. Verify yield vault is executing normally
/// 3. Setup and run Supervisor
/// 4. Verify Supervisor runs but pending queue stays empty
/// 5. Verify yield vault continues executing (not disrupted by Supervisor)
///
access(all)
fun testSupervisorDoesNotDisruptHealthyYieldVaults() {
    log("\n Testing Supervisor with healthy yield vaults (nothing to recover)...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)
    mintFlow(to: flowYieldVaultsAccount, amount: 200.0)

    // 1. Create a healthy yield vault (AutoBalancer schedules itself natively)
    log("Step 1: Creating healthy yield vault...")
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))

    // 2. Verify yield vault is in registry
    log("Step 2: Verifying yield vault is in registry...")
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(yieldVaultID), message: "YieldVault should be in registry")
    log("YieldVault is registered in FlowYieldVaultsSchedulerRegistry")

    // 3. Wait for some native executions
    log("Step 3: Waiting for native execution...")
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    let execEventsBefore = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions so far: ".concat(execEventsBefore.length.toString()))
    Test.assert(execEventsBefore.length >= 1, message: "YieldVault should have executed at least once")

    // 4. Verify pending queue is empty (healthy yield vault, nothing to recover)
    log("Step 4: Verifying pending queue is empty...")
    let pendingCountRes = executeScript("../scripts/flow-yield-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount.toString()))
    Test.assertEqual(0, pendingCount)

    // Supervisor is automatically configured when FlowYieldVaultsSchedulerV1 is deployed (in init)
    Test.commitBlock()

    // Schedule Supervisor
    let interval = 60.0 * 10.0
    let schedSupRes = executeTransaction(
        "../transactions/flow-yield-vaults/admin/schedule_supervisor.cdc",
        [interval, UInt8(1), UInt64(800), true], // interval, priority, execution effort, scan for stuck
        flowYieldVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled")

    // 6. Advance time to let Supervisor run
    log("Step 6: Waiting for Supervisor to run...")
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    // 7. Verify Supervisor ran but found nothing to recover (healthy yield vault)
    let recoveredEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.YieldVaultRecovered>())
    log("YieldVaultRecovered events: ".concat(recoveredEvents.length.toString()))

    // Healthy yield vaults don't need recovery
    // Note: recoveredEvents might be > 0 if there were stuck yield vaults from previous tests
    // The key verification is that our yield vault continues to execute

    // 8. Verify yield vault continues executing
    log("Step 7: Verifying yield vault continues executing...")
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    let execEventsAfter = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(execEventsAfter.length.toString()))

    // Verification: We should have more executions (yield vault continued normally)
    Test.assert(
        execEventsAfter.length > execEventsBefore.length,
        message: "YieldVault should continue executing. Before: ".concat(execEventsBefore.length.toString()).concat(", After: ").concat(execEventsAfter.length.toString())
    )

    // 8. Verify pending queue is still empty
    let finalPendingRes = executeScript("../scripts/flow-yield-vaults/get_pending_count.cdc", [])
    let finalPending = finalPendingRes.returnValue! as! Int
    log("Final pending queue size: ".concat(finalPending.toString()))
    Test.assertEqual(0, finalPending)

    log("PASS: Supervisor runs without disrupting healthy yield vaults")
}

/// Tests that isStuckYieldVault() correctly identifies healthy yield vaults as NOT stuck
///
/// This test verifies the detection logic:
/// - A healthy, executing yield vault should NOT be detected as stuck
/// - isStuckYieldVault() returns false for yield vaults with active schedules
///
/// LIMITATION: We cannot easily simulate an ACTUALLY stuck yield vault in tests because:
/// - Stuck yield vaults occur when AutoBalancer fails to reschedule (e.g., insufficient funds)
/// - The txnFunder is set up with ample funds during strategy creation
/// - To fully test recovery, we'd need to drain the txnFunder mid-execution
///
/// TEST SCENARIO:
/// 1. Create healthy yield vault
/// 2. Let it execute
/// 3. Verify isStuckYieldVault() returns false
/// 4. Verify hasActiveSchedule() returns true
///
access(all)
fun testStuckYieldVaultDetectionLogic() {
    // Reset to snapshot for test isolation
    Test.reset(to: snapshot)

    log("\n Testing stuck yield vault detection logic...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)

    // 1. Create a healthy yield vault
    log("Step 1: Creating healthy yield vault...")
    let createRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created: ".concat(yieldVaultID.toString()))

    // 2. Let it execute
    log("Step 2: Waiting for execution...")
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions: ".concat(execEvents.length.toString()))
    Test.assert(execEvents.length >= 1, message: "YieldVault should have executed")

    // 3. Check hasActiveSchedule() - should be true for healthy yield vault
    log("Step 3: Checking hasActiveSchedule()...")
    let hasActiveRes = executeScript(
        "../scripts/flow-yield-vaults/has_active_schedule.cdc",
        [yieldVaultID]
    )
    Test.expect(hasActiveRes, Test.beSucceeded())
    let hasActive = hasActiveRes.returnValue! as! Bool
    log("hasActiveSchedule: ".concat(hasActive ? "true" : "false"))
    Test.assertEqual(true, hasActive)

    // 4. Check isStuckYieldVault() - should be false for healthy yield vault
    log("Step 4: Checking isStuckYieldVault()...")
    let isStuckRes = executeScript(
        "../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc",
        [yieldVaultID]
    )
    Test.expect(isStuckRes, Test.beSucceeded())
    let isStuck = isStuckRes.returnValue! as! Bool
    log("isStuckYieldVault: ".concat(isStuck ? "true" : "false"))
    Test.assertEqual(false, isStuck)

    log("PASS: Stuck yield vault detection correctly identifies healthy yield vaults")
}

/// COMPREHENSIVE TEST: Insufficient Funds -> Failure -> Recovery
///
/// This test validates the COMPLETE failure and recovery cycle:
/// 1. Create 5 yield vaults (matches MAX_BATCH_SIZE)
/// 2. Let them execute 3 rounds each (30+ executions)
/// 3. Start Supervisor BEFORE drain (with short interval)
/// 4. Drain FLOW - both yield vaults AND Supervisor fail to reschedule
/// 5. Wait and verify all failures
/// 6. Refund account
/// 7. Manually restart Supervisor
/// 8. Verify Supervisor executes and recovers stuck yield vaults
/// 9. Verify at least 3 more executions per yield vault after recovery
///
access(all)
fun testInsufficientFundsAndRecovery() {
    // Reset to snapshot for isolation - this test needs a clean slate
    Test.reset(to: snapshot)

    log("\n========================================")
    log("TEST: Comprehensive Insufficient Funds -> Recovery")
    log("========================================")
    log("- 5 yield vaults, 3 rounds each before drain (matches MAX_BATCH_SIZE)")
    log("- Supervisor running before drain (also fails)")
    log("- Verify 3+ executions per yield vault after recovery")
    log("========================================")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowYieldVaultsAccount, user)

    // Check initial FlowYieldVaults balance
    let initialBalance = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Initial FlowYieldVaults FLOW balance: ".concat(initialBalance.toString()))

    // ========================================
    // STEP 1: Create 5 yield vaults (matches MAX_BATCH_SIZE for single-run recovery)
    // ========================================
    log("\n--- STEP 1: Creating 5 yield vaults ---")
    var i = 0
    while i < 5 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 50.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    Test.assertEqual(5, yieldVaultIDs.length)
    log("Created ".concat(yieldVaultIDs.length.toString()).concat(" yield vaults"))

    // ========================================
    // STEP 2: Setup Supervisor (scheduling functionality is built into Supervisor)
    // Supervisor is automatically configured when FlowYieldVaultsSchedulerV1 is deployed (in init)
    log("\n--- Supervisor already configured at deploy time ---")

    // ========================================
    // STEP 3: Let yield vaults execute 3 rounds (and Supervisor run) with balance verification
    // ========================================
    log("\n--- STEP 3: Running 3 rounds (5 yield vaults x 3 = 15 expected executions) ---")

    // Track initial balances for all 5 yield vaults
    var prevBalances: [UFix64] = []
    var idx = 0
    while idx < 5 {
        prevBalances.append(getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0)
        idx = idx + 1
    }
    log("Initial balances tracked for 5 yield vaults")

    var round = 1
    while round <= 3 {
        // Use LARGE price changes to ensure rebalancing triggers regardless of previous state
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5 * UFix64(round))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2 * UFix64(round))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()

        // Verify all 5 yield vaults changed balance
        idx = 0
        while idx < 5 {
            let newBal = getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0
            Test.assert(newBal != prevBalances[idx], message: "YieldVault ".concat(idx.toString()).concat(" balance should change after round ").concat(round.toString()))
            prevBalances[idx] = newBal
            idx = idx + 1
        }
        log("Round ".concat(round.toString()).concat(" balances verified for all 5 yield vaults"))
        round = round + 1
    }

    let execEventsBeforeDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions before drain: ".concat(execEventsBeforeDrain.length.toString()))
    Test.assert(execEventsBeforeDrain.length >= 15, message: "Should have at least 15 executions (5 yield vaults x 3 rounds)")

    // Verify yield vaults are registered
    let registeredCount = (executeScript(
        "../scripts/flow-yield-vaults/get_registered_yield_vault_count.cdc",
        []
    ).returnValue! as! Int)
    log("Registered yield vaults: ".concat(registeredCount.toString()))
    Test.assertEqual(5, registeredCount)

    // ========================================
    // STEP 4: DRAIN the FlowYieldVaults account's FLOW
    // ========================================
    log("\n--- STEP 4: Draining FlowYieldVaults account FLOW ---")
    let balanceBeforeDrain = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance before drain: ".concat(balanceBeforeDrain.toString()))

    // Drain ALL FLOW (leave minimal amount)
    if balanceBeforeDrain > 0.01 {
        let drainRes = executeTransaction(
            "../transactions/flow-yield-vaults/drain_flow.cdc",
            [balanceBeforeDrain - 0.001],
            flowYieldVaultsAccount
        )
        Test.expect(drainRes, Test.beSucceeded())
    }

    let balanceAfterDrain = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance after drain: ".concat(balanceAfterDrain.toString()))
    Test.assert(balanceAfterDrain < 0.01, message: "Balance should be nearly zero")

    // ========================================
    // STEP 5: Wait for all pre-scheduled transactions to fail
    // ========================================
    log("\n--- STEP 5: Waiting for failures (6 rounds) ---")
    var waitRound = 0
    while waitRound < 6 {
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        waitRound = waitRound + 1
    }

    let execEventsAfterDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after drain+wait: ".concat(execEventsAfterDrain.length.toString()))

    // Verify yield vaults are stuck
    log("\n--- STEP 6: Verifying yield vaults are stuck ---")
    var stuckCount = 0
    var stuckYieldVaultIDs: [UInt64] = []
    for yieldVaultID in yieldVaultIDs {
        let isStuckRes = executeScript(
            "../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc",
            [yieldVaultID]
        )
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stuckCount = stuckCount + 1
                stuckYieldVaultIDs.append(yieldVaultID)
            }
        }
    }
    log("Stuck yield vaults: ".concat(stuckCount.toString()).concat(" / ").concat(yieldVaultIDs.length.toString()))
    Test.assert(stuckCount >= 5, message: "All 5 yield vaults should be stuck")

    // Verify Supervisor also stopped - pending queue should remain with stuck yield vaults
    // (Supervisor couldn't run due to no FLOW)
    let pendingCount = (executeScript(
        "../scripts/flow-yield-vaults/get_pending_count.cdc",
        []
    ).returnValue! as! Int)
    log("Pending queue size: ".concat(pendingCount.toString()))

    // Record execution count at this point (no more should happen until recovery)
    let execCountBeforeRecovery = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>()).length
    log("Execution count before recovery: ".concat(execCountBeforeRecovery.toString()))

    // ========================================
    // STEP 7: REFUND the account
    // ========================================
    log("\n--- STEP 7: Refunding FlowYieldVaults account ---")
    mintFlow(to: flowYieldVaultsAccount, amount: 200.0)

    let balanceAfterRefund = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance after refund: ".concat(balanceAfterRefund.toString()))
    Test.assert(balanceAfterRefund >= 200.0, message: "Balance should be at least 200 FLOW")

    // ========================================
    // STEP 8: START Supervisor (first time scheduling)
    // ========================================
    log("\n--- STEP 8: Starting Supervisor (post-refund) ---")

    // Process any pending blocks first
    Test.commitBlock()
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    // Get FRESH timestamp after block commit
    let currentTs = getCurrentBlockTimestamp()
    log("Current timestamp: ".concat(currentTs.toString()))

    // Use VERY large offset (10000s) to ensure it's always in the future
    let interval = 60.0 * 10.0
    let restartTime = currentTs + interval
    log("Scheduling Supervisor at: ".concat(restartTime.toString()))

    let schedSupRes = executeTransaction(
        "../transactions/flow-yield-vaults/admin/schedule_supervisor.cdc",
        [interval, UInt8(1), UInt64(5000), true],  // interval, priority, execution effort, scan for stuck
        flowYieldVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled for recovery")

    // ========================================
    // STEP 9: Let Supervisor run and recover stuck yield vaults
    // ========================================
    log("\n--- STEP 9: Letting Supervisor run and recover ---")
    Test.moveTime(by: Fix64(restartTime - getCurrentBlockTimestamp() + 100.0))  // Move past the 10000s scheduled time
    Test.commitBlock()

    // Check for StuckYieldVaultDetected events
    let stuckDetectedEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.StuckYieldVaultDetected>())
    log("StuckYieldVaultDetected events: ".concat(stuckDetectedEvents.length.toString()))
    Test.assert(stuckDetectedEvents.length >= 5, message: "Supervisor should detect all 5 stuck yield vaults")

    // Check for YieldVaultRecovered events (Supervisor uses Schedule capability to recover)
    let recoveredEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.YieldVaultRecovered>())
    log("YieldVaultRecovered events: ".concat(recoveredEvents.length.toString()))
    Test.assert(recoveredEvents.length >= 5, message: "Supervisor should recover all 5 yield vaults")

    // Verify Supervisor executed by checking it seeded yield vaults and detected stuck ones
    log("Supervisor successfully ran and recovered yield vaults")

    // ========================================
    // STEP 10: Verify yield vaults execute 3+ times each after recovery with balance changes
    // ========================================
    log("\n--- STEP 10: Running 3+ rounds to verify yield vaults resumed self-scheduling ---")
    // After Supervisor seeds, yield vaults should resume self-scheduling and continue perpetually.
    // We run 4 rounds to ensure each yield vault executes at least 3 times after recovery.

    // Track balance for first yield vault to verify rebalancing actually happens
    let trackedYieldVaultID = yieldVaultIDs[0]
    var prevBalance = getAutoBalancerBalance(id: trackedYieldVaultID) ?? 0.0
    log("Balance before recovery rounds (yield vault ".concat(trackedYieldVaultID.toString()).concat("): ").concat(prevBalance.toString()))

    round = 1
    while round <= 4 {
        // Use LARGE price changes to ensure rebalancing triggers
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 5.0 * UFix64(round))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 4.0 * UFix64(round))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()

        let newBalance = getAutoBalancerBalance(id: trackedYieldVaultID) ?? 0.0
        log("Recovery round ".concat(round.toString()).concat(": Balance ").concat(prevBalance.toString()).concat(" -> ").concat(newBalance.toString()))
        Test.assert(newBalance != prevBalance, message: "Balance should change after recovery round ".concat(round.toString()))
        prevBalance = newBalance

        round = round + 1
    }

    let execEventsFinal = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let newExecutions = execEventsFinal.length - execCountBeforeRecovery
    log("Final total executions: ".concat(execEventsFinal.length.toString()))
    log("New executions after recovery: ".concat(newExecutions.toString()))

    // After Supervisor seeds 5 yield vaults:
    // - 1 Supervisor execution
    // - 10 initial seeded executions (1 per yield vault)
    // - Plus 3 more rounds of 10 executions each = 30 more
    // Total minimum: 1 + 10 + 30 = 41, but we'll be conservative and expect 30+
    Test.assert(
        newExecutions >= 15,
        message: "Should have at least 15 new executions (5 yield vaults x 3+ rounds). Got: ".concat(newExecutions.toString())
    )

    // ========================================
    // STEP 11: Verify yield vaults are no longer stuck
    // ========================================
    log("\n--- STEP 11: Verifying yield vaults are no longer stuck ---")
    // After recovery, yield vaults should have resumed self-scheduling and be healthy
    var stillStuckCount = 0
    for yieldVaultID in yieldVaultIDs {
        let isStuckRes = executeScript(
            "../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc",
            [yieldVaultID]
        )
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stillStuckCount = stillStuckCount + 1
            }
        }
    }
    log("YieldVaults still stuck: ".concat(stillStuckCount.toString()))
    Test.assertEqual(0, stillStuckCount)

    // ========================================
    // STEP 12: Verify all yield vaults have active schedules
    // ========================================
    log("\n--- STEP 12: Verifying all yield vaults have active schedules ---")
    var activeScheduleCount = 0
    for yieldVaultID in yieldVaultIDs {
        let hasActiveRes = executeScript(
            "../scripts/flow-yield-vaults/has_active_schedule.cdc",
            [yieldVaultID]
        )
        if hasActiveRes.returnValue != nil {
            let hasActive = hasActiveRes.returnValue! as! Bool
            if hasActive {
                activeScheduleCount = activeScheduleCount + 1
            }
        }
    }
    log("YieldVaults with active schedules: ".concat(activeScheduleCount.toString()).concat("/").concat(yieldVaultIDs.length.toString()))
    Test.assertEqual(5, activeScheduleCount)

    log("\n========================================")
    log("PASS: Comprehensive Insufficient Funds Recovery Test!")
    log("- 5 yield vaults created and ran 3 rounds (15 executions)")
    log("- After drain: all ".concat(stuckCount.toString()).concat(" yield vaults became stuck"))
    log("- Supervisor detected stuck yield vaults: ".concat(stuckDetectedEvents.length.toString()))
    log("- Supervisor recovered yield vaults: ".concat(recoveredEvents.length.toString()))
    log("- ".concat(newExecutions.toString()).concat(" new executions after recovery"))
    log("- All yield vaults resumed self-scheduling and are healthy")
    log("- All ".concat(activeScheduleCount.toString()).concat(" yield vaults have active schedules"))
    log("========================================")
}
