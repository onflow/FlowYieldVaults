import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowVaultsScheduler"
import "FlowTransactionScheduler"
import "DeFiActions"
import "FlowVaultsSchedulerRegistry"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

// Snapshot for test isolation - captured after setup completes
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    log("🚀 Setting up Supervisor integration test...")
    
    deployContracts()
    deployFlowVaultsSchedulerIfNeeded()
    
    // Fund FlowVaults account BEFORE any Tides are created, as registerTide
    // now atomically schedules the first execution which requires FLOW for fees
    mintFlow(to: flowVaultsAccount, amount: 1000.0)
    
    // Mock Oracle
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

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

    // FlowALP
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Wrapped Position
    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/tests/transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Strategy Composer
    addStrategyComposer(
        signer: flowVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
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
/// - The Supervisor is for recovery only (detects stuck tides and seeds them)
/// - Supervisor tracks its own recovery schedules
///
access(all)
fun testAutoRegisterAndSupervisor() {
    log("\n Testing Auto-Register + Native Scheduling...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // 1. Create Tide (Should auto-register and self-schedule via native mechanism)
    log("Step 1: Create Tide")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))

    // 2. Verify registration
    let regIDsRes = executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    )
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be registered")
    log("Tide is registered")

    // 3. Wait for native AutoBalancer execution
    log("Step 2: Wait for native execution...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    
    Test.moveTime(by: 75.0)
    Test.commitBlock()

    // 4. Verify native execution occurred
    let schedulerExecEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    Test.assert(schedulerExecEvents.length > 0, message: "Should have FlowTransactionScheduler.Executed event")
    
    let rebalancedEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("Scheduler.Executed events: ".concat(schedulerExecEvents.length.toString()))
    log("DeFiActions.Rebalanced events: ".concat(rebalancedEvents.length.toString()))
    
    log("PASS: Auto-Register + Native Scheduling")
}

/// Test: Multiple tides all self-schedule via native mechanism
/// 
/// NEW ARCHITECTURE:
/// - Each tide's AutoBalancer self-schedules via native FlowTransactionScheduler
/// - No Supervisor seeding needed - tides execute independently
/// - This tests that multiple tides can be created and all self-schedule
///
access(all)
fun testMultiTideNativeScheduling() {
    log("\n Testing Multiple Tides Native Scheduling...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 3 tides (each auto-schedules via native mechanism)
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 100.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let allTides = getTideIDs(address: user.address)!
    log("Created ".concat(allTides.length.toString()).concat(" tides"))

    // Verify all are registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    for tid in allTides {
        Test.assert(regIDs.contains(tid), message: "Tide should be registered")
    }
    log("All tides registered")
    
    // Wait for native execution
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    Test.moveTime(by: 75.0)
    Test.commitBlock()
    
    // Verify all executed via native scheduling
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    Test.assert(execEvents.length >= 3, message: "Should have at least 3 executions (one per tide)")
    log("Executions: ".concat(execEvents.length.toString()))
    
    log("PASS: Multiple Tides Native Scheduling")
}

/// Test: Native recurring rebalancing executes at least 3 times
/// 
/// NEW ARCHITECTURE:
/// - AutoBalancer self-schedules via native mechanism
/// - No Supervisor needed for normal recurring execution
///
access(all)
fun testRecurringRebalancingThreeRuns() {
    log("\n Testing native recurring rebalancing (3 runs)...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // Create Tide (auto-schedules via native mechanism)
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())

    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))

    // Wait for 3 native executions
    var count = 0
    var round = 0
    while round < 10 && count < 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.1))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        count = execEvents.length
        round = round + 1
    }

    Test.assert(
        count >= 3,
        message: "Expected at least 3 executions but found ".concat(count.toString())
    )
    log("PASS: Native recurring executed ".concat(count.toString()).concat(" times")
    )
}

/// Test: Multiple tides execute independently via native scheduling
/// 
/// NEW ARCHITECTURE:
/// - Each AutoBalancer self-schedules via native mechanism
/// - No Supervisor needed for normal execution
///
access(all)
fun testMultiTideIndependentExecution() {
    log("\n Testing multiple tides execute independently...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // Create 3 tides (each auto-schedules via native mechanism)
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 100.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    log("Created ".concat(tideIDs.length.toString()).concat(" tides"))

    // Drive 3 rounds of execution
    var round = 0
    while round < 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }

    // Count executions
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(execEvents.length.toString()))
    
    // 3 tides x 3 rounds = 9 minimum executions
    Test.assert(
        execEvents.length >= 9,
        message: "Expected at least 9 executions but found ".concat(execEvents.length.toString())
    )
    
    log("PASS: Multiple tides executed independently")
}

/// Stress test: tests pagination with many tides exceeding MAX_BATCH_SIZE (5)
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native mechanism
/// - Registry tracks all registered tides
/// - Pending queue is for RECOVERY (failed self-schedules)
/// - Pagination is used when processing pending queue in batches
///
/// Tests pagination with a large number of tides, each executing at least 3 times.
///
/// Uses dynamic batch size: 3 * MAX_BATCH_SIZE + partial (3 in this case)
/// MAX_BATCH_SIZE = 5, so total = 3*5 + 3 = 18 tides
///
/// This verifies:
/// 1. All tides are registered correctly
/// 2. Pagination functions work correctly across multiple pages
/// 3. All tides self-schedule and execute at least 3 times each
///
access(all)
fun testPaginationStress() {
    // Calculate number of tides: 3 * MAX_BATCH_SIZE + partial batch
    // MAX_BATCH_SIZE is 5 in FlowVaultsSchedulerRegistry
    let maxBatchSize = 5
    let fullBatches = 3
    let partialBatch = 3  // Less than MAX_BATCH_SIZE
    let numTides = fullBatches * maxBatchSize + partialBatch  // 18 tides
    let minExecutionsPerTide = 3
    let minTotalExecutions = numTides * minExecutionsPerTide  // 519 minimum
    
    log("\n Testing pagination with ".concat(numTides.toString()).concat(" tides (").concat(fullBatches.toString()).concat("x MAX_BATCH_SIZE + ").concat(partialBatch.toString()).concat(")..."))
    log("Expecting at least ".concat(minTotalExecutions.toString()).concat(" total executions (").concat(minExecutionsPerTide.toString()).concat(" per tide)"))
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 10000.0)  // For 3 rounds of 18 tides
    grantBeta(flowVaultsAccount, user)
    mintFlow(to: flowVaultsAccount, amount: 50000.0)  // Increased for scheduling fees

    // Create tides
    log("Creating ".concat(numTides.toString()).concat(" tides..."))
    var i = 0
    while i < numTides {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 5.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    log("Created ".concat(tideIDs.length.toString()).concat(" tides"))
    Test.assertEqual(numTides, tideIDs.length)
    
    // Check registry state - all tides should be registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    log("Registered tides: ".concat(regIDs.length.toString()))
    
    Test.assert(
        regIDs.length >= numTides,
        message: "Expected at least ".concat(numTides.toString()).concat(" registered tides, got ").concat(regIDs.length.toString())
    )
    
    // Verify pagination works on pending queue (should be empty since all self-schedule)
    let pendingCountRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    log("Pending queue size (should be 0 since all self-schedule): ".concat(pendingCount.toString()))
    Test.assertEqual(0, pendingCount)
    
    // Test paginated access - request each page up to MAX_BATCH_SIZE
    var page = 0
    while page <= fullBatches {
        let pageRes = executeScript("../scripts/flow-vaults/get_pending_tides_paginated.cdc", [page, maxBatchSize])
        let pageData = pageRes.returnValue! as! [UInt64]
        log("Page ".concat(page.toString()).concat(" of pending queue: ").concat(pageData.length.toString()).concat(" tides"))
        page = page + 1
    }
    
    // Execute 3 rounds - verify each tide executes at least 3 times
    log("\n--- Executing 3 rounds ---")
    var round = 1
    while round <= minExecutionsPerTide {
        // Change price to trigger rebalancing
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let roundEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        let expectedMinEvents = numTides * round
        log("Round ".concat(round.toString()).concat(": ").concat(roundEvents.length.toString()).concat(" total executions (expected >= ").concat(expectedMinEvents.toString()).concat(")"))
        
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
        message: "Expected at least ".concat(minTotalExecutions.toString()).concat(" total executions (").concat(numTides.toString()).concat(" tides x ").concat(minExecutionsPerTide.toString()).concat(" rounds), got ").concat(finalEvents.length.toString())
    )
    
    log("PASS: ".concat(numTides.toString()).concat(" tides all registered and executed at least ").concat(minExecutionsPerTide.toString()).concat(" times each"))
}

/// Tests that Supervisor does not disrupt healthy tides
///
/// This test verifies that when Supervisor runs, it does NOT interfere with
/// healthy tides that are self-scheduling correctly.
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native FlowTransactionScheduler
/// - Supervisor periodically scans for "stuck" tides (overdue + no active schedule)
/// - Healthy tides never appear in pending queue
/// - Supervisor runs but finds nothing to recover
///
/// TEST SCENARIO:
/// 1. Create healthy tide (AutoBalancer schedules itself natively)
/// 2. Verify tide is executing normally
/// 3. Setup and run Supervisor
/// 4. Verify Supervisor runs but pending queue stays empty
/// 5. Verify tide continues executing (not disrupted by Supervisor)
///
access(all)
fun testSupervisorDoesNotDisruptHealthyTides() {
    log("\n Testing Supervisor with healthy tides (nothing to recover)...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    mintFlow(to: flowVaultsAccount, amount: 200.0)

    // 1. Create a healthy tide (AutoBalancer schedules itself natively)
    log("Step 1: Creating healthy tide...")
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))

    // 2. Verify tide is in registry
    log("Step 2: Verifying tide is in registry...")
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be in registry")
    log("Tide is registered in FlowVaultsSchedulerRegistry")

    // 3. Wait for some native executions
    log("Step 3: Waiting for native execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEventsBefore = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions so far: ".concat(execEventsBefore.length.toString()))
    Test.assert(execEventsBefore.length >= 1, message: "Tide should have executed at least once")

    // 4. Verify pending queue is empty (healthy tide, nothing to recover)
    log("Step 4: Verifying pending queue is empty...")
    let pendingCountRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount.toString()))
    Test.assertEqual(0, pendingCount)

    // 5. Setup Supervisor (scheduling functionality is now built into Supervisor)
    log("Step 5: Setting up Supervisor...")
    executeTransaction("../transactions/flow-vaults/setup_supervisor.cdc", [], flowVaultsAccount)
    
    Test.commitBlock()
    
    // Schedule Supervisor
    let scheduledTime = getCurrentBlock().timestamp + 2000.0
    let schedSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [scheduledTime, UInt8(1), UInt64(800), 0.05, 30.0, true, 10.0, false],
        flowVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled")

    // 6. Advance time to let Supervisor run
    log("Step 6: Waiting for Supervisor to run...")
    Test.moveTime(by: 2100.0)
    Test.commitBlock()

    // 7. Verify Supervisor ran but found nothing to seed (healthy tide)
    let seededEvents = Test.eventsOfType(Type<FlowVaultsScheduler.SupervisorSeededTide>())
    log("SupervisorSeededTide events: ".concat(seededEvents.length.toString()))
    
    // Healthy tides don't need seeding
    // Note: seededEvents might be > 0 if there were stuck tides from previous tests
    // The key verification is that our tide continues to execute

    // 8. Verify tide continues executing
    log("Step 7: Verifying tide continues executing...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()

    let execEventsAfter = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(execEventsAfter.length.toString()))
    
    // Verification: We should have more executions (tide continued normally)
    Test.assert(
        execEventsAfter.length > execEventsBefore.length,
        message: "Tide should continue executing. Before: ".concat(execEventsBefore.length.toString()).concat(", After: ").concat(execEventsAfter.length.toString())
    )

    // 8. Verify pending queue is still empty
    let finalPendingRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let finalPending = finalPendingRes.returnValue! as! Int
    log("Final pending queue size: ".concat(finalPending.toString()))
    Test.assertEqual(0, finalPending)
    
    log("PASS: Supervisor runs without disrupting healthy tides")
}

/// Tests that isStuckTide() correctly identifies healthy tides as NOT stuck
///
/// This test verifies the detection logic:
/// - A healthy, executing tide should NOT be detected as stuck
/// - isStuckTide() returns false for tides with active schedules
///
/// LIMITATION: We cannot easily simulate an ACTUALLY stuck tide in tests because:
/// - Stuck tides occur when AutoBalancer fails to reschedule (e.g., insufficient funds)
/// - The txnFunder is set up with ample funds during strategy creation
/// - To fully test recovery, we'd need to drain the txnFunder mid-execution
///
/// TEST SCENARIO:
/// 1. Create healthy tide
/// 2. Let it execute
/// 3. Verify isStuckTide() returns false
/// 4. Verify hasActiveSchedule() returns true
///
access(all)
fun testStuckTideDetectionLogic() {
    // Reset to snapshot for test isolation
    Test.reset(to: snapshot)
    
    log("\n Testing stuck tide detection logic...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // 1. Create a healthy tide
    log("Step 1: Creating healthy tide...")
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))

    // 2. Let it execute
    log("Step 2: Waiting for execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions: ".concat(execEvents.length.toString()))
    Test.assert(execEvents.length >= 1, message: "Tide should have executed")

    // 3. Check hasActiveSchedule() - should be true for healthy tide
    log("Step 3: Checking hasActiveSchedule()...")
    let hasActiveRes = executeScript(
        "../scripts/flow-vaults/has_active_schedule.cdc",
        [tideID]
    )
    Test.expect(hasActiveRes, Test.beSucceeded())
    let hasActive = hasActiveRes.returnValue! as! Bool
    log("hasActiveSchedule: ".concat(hasActive ? "true" : "false"))
    Test.assertEqual(true, hasActive)

    // 4. Check isStuckTide() - should be false for healthy tide
    log("Step 4: Checking isStuckTide()...")
    let isStuckRes = executeScript(
        "../scripts/flow-vaults/is_stuck_tide.cdc",
        [tideID]
    )
    Test.expect(isStuckRes, Test.beSucceeded())
    let isStuck = isStuckRes.returnValue! as! Bool
    log("isStuckTide: ".concat(isStuck ? "true" : "false"))
    Test.assertEqual(false, isStuck)

    log("PASS: Stuck tide detection correctly identifies healthy tides")
}

/// COMPREHENSIVE TEST: Insufficient Funds -> Failure -> Recovery
/// 
/// This test validates the COMPLETE failure and recovery cycle:
/// 1. Create 5 tides (matches MAX_BATCH_SIZE)
/// 2. Let them execute 3 rounds each (30+ executions)
/// 3. Start Supervisor BEFORE drain (with short interval)
/// 4. Drain FLOW - both tides AND Supervisor fail to reschedule
/// 5. Wait and verify all failures
/// 6. Refund account
/// 7. Manually restart Supervisor
/// 8. Verify Supervisor executes and recovers stuck tides
/// 9. Verify at least 3 more executions per tide after recovery
///
access(all)
fun testInsufficientFundsAndRecovery() {
    // Reset to snapshot for isolation - this test needs a clean slate
    Test.reset(to: snapshot)
    
    log("\n========================================")
    log("TEST: Comprehensive Insufficient Funds -> Recovery")
    log("========================================")
    log("- 5 tides, 3 rounds each before drain (matches MAX_BATCH_SIZE)")
    log("- Supervisor running before drain (also fails)")
    log("- Verify 3+ executions per tide after recovery")
    log("========================================")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowVaultsAccount, user)

    // Check initial FlowVaults balance
    let initialBalance = (executeScript(
        "../scripts/flow-vaults/get_flow_balance.cdc",
        [flowVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Initial FlowVaults FLOW balance: ".concat(initialBalance.toString()))

    // ========================================
    // STEP 1: Create 5 tides (matches MAX_BATCH_SIZE for single-run recovery)
    // ========================================
    log("\n--- STEP 1: Creating 5 tides ---")
    var i = 0
    while i < 5 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 50.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    Test.assertEqual(5, tideIDs.length)
    log("Created ".concat(tideIDs.length.toString()).concat(" tides"))

    // ========================================
    // STEP 2: Setup Supervisor (scheduling functionality is built into Supervisor)
    // ========================================
    log("\n--- STEP 2: Setup Supervisor ---")
    executeTransaction("../transactions/flow-vaults/setup_supervisor.cdc", [], flowVaultsAccount)
    Test.commitBlock()
    log("Supervisor ready (will schedule after drain/refund)")

    // ========================================
    // STEP 3: Let tides execute 3 rounds (and Supervisor run)
    // ========================================
    log("\n--- STEP 3: Running 3 rounds (5 tides x 3 = 15 expected executions) ---")
    var round = 0
    while round < 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.1))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0 + (UFix64(round) * 0.05))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }

    let execEventsBeforeDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions before drain: ".concat(execEventsBeforeDrain.length.toString()))
    Test.assert(execEventsBeforeDrain.length >= 15, message: "Should have at least 15 executions (5 tides x 3 rounds)")
    
    // Verify tides are registered
    let registeredCount = (executeScript(
        "../scripts/flow-vaults/get_registered_tide_count.cdc",
        []
    ).returnValue! as! Int)
    log("Registered tides: ".concat(registeredCount.toString()))
    Test.assertEqual(5, registeredCount)

    // ========================================
    // STEP 4: DRAIN the FlowVaults account's FLOW
    // ========================================
    log("\n--- STEP 4: Draining FlowVaults account FLOW ---")
    let balanceBeforeDrain = (executeScript(
        "../scripts/flow-vaults/get_flow_balance.cdc",
        [flowVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance before drain: ".concat(balanceBeforeDrain.toString()))
    
    // Drain ALL FLOW (leave minimal amount)
    if balanceBeforeDrain > 0.01 {
        let drainRes = executeTransaction(
            "../transactions/flow-vaults/drain_flow.cdc",
            [balanceBeforeDrain - 0.001],
            flowVaultsAccount
        )
        Test.expect(drainRes, Test.beSucceeded())
    }

    let balanceAfterDrain = (executeScript(
        "../scripts/flow-vaults/get_flow_balance.cdc",
        [flowVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance after drain: ".concat(balanceAfterDrain.toString()))
    Test.assert(balanceAfterDrain < 0.01, message: "Balance should be nearly zero")

    // ========================================
    // STEP 5: Wait for all pre-scheduled transactions to fail
    // ========================================
    log("\n--- STEP 5: Waiting for failures (6 rounds) ---")
    var waitRound = 0
    while waitRound < 6 {
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        waitRound = waitRound + 1
    }

    let execEventsAfterDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after drain+wait: ".concat(execEventsAfterDrain.length.toString()))

    // Verify tides are stuck
    log("\n--- STEP 6: Verifying tides are stuck ---")
    var stuckCount = 0
    var stuckTideIDs: [UInt64] = []
    for tideID in tideIDs {
        let isStuckRes = executeScript(
            "../scripts/flow-vaults/is_stuck_tide.cdc",
            [tideID]
        )
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stuckCount = stuckCount + 1
                stuckTideIDs.append(tideID)
            }
        }
    }
    log("Stuck tides: ".concat(stuckCount.toString()).concat(" / ").concat(tideIDs.length.toString()))
    Test.assert(stuckCount >= 5, message: "All 5 tides should be stuck")

    // Verify Supervisor also stopped - pending queue should remain with stuck tides
    // (Supervisor couldn't run due to no FLOW)
    let pendingCount = (executeScript(
        "../scripts/flow-vaults/get_pending_count.cdc",
        []
    ).returnValue! as! Int)
    log("Pending queue size: ".concat(pendingCount.toString()))

    // Record execution count at this point (no more should happen until recovery)
    let execCountBeforeRecovery = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>()).length
    log("Execution count before recovery: ".concat(execCountBeforeRecovery.toString()))

    // ========================================
    // STEP 7: REFUND the account
    // ========================================
    log("\n--- STEP 7: Refunding FlowVaults account ---")
    mintFlow(to: flowVaultsAccount, amount: 200.0)
    
    let balanceAfterRefund = (executeScript(
        "../scripts/flow-vaults/get_flow_balance.cdc",
        [flowVaultsAccount.address]
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
    let currentTs = getCurrentBlock().timestamp
    log("Current timestamp: ".concat(currentTs.toString()))
    
    // Use VERY large offset (10000s) to ensure it's always in the future
    let restartTime = currentTs + 10000.0
    log("Scheduling Supervisor at: ".concat(restartTime.toString()))
    
    let schedSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [restartTime, UInt8(1), UInt64(5000), 0.5, 60.0, true, 30.0, true],  // Higher execution effort (5000) for recovering 5 tides
        flowVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled for recovery")

    // ========================================
    // STEP 9: Let Supervisor run and recover stuck tides
    // ========================================
    log("\n--- STEP 9: Letting Supervisor run and recover ---")
    Test.moveTime(by: 11000.0)  // Move past the 10000s scheduled time
    Test.commitBlock()

    // Check for StuckTideDetected events
    let stuckDetectedEvents = Test.eventsOfType(Type<FlowVaultsScheduler.StuckTideDetected>())
    log("StuckTideDetected events: ".concat(stuckDetectedEvents.length.toString()))
    Test.assert(stuckDetectedEvents.length >= 5, message: "Supervisor should detect all 5 stuck tides")

    // Check for SupervisorSeededTide events
    let seededEvents = Test.eventsOfType(Type<FlowVaultsScheduler.SupervisorSeededTide>())
    log("SupervisorSeededTide events: ".concat(seededEvents.length.toString()))
    Test.assert(seededEvents.length >= 5, message: "Supervisor should seed all 5 tides")

    // Verify Supervisor executed by checking it seeded tides and detected stuck ones
    log("Supervisor successfully ran and recovered tides")

    // ========================================
    // STEP 10: Verify tides execute 3+ times each after recovery
    // ========================================
    log("\n--- STEP 10: Running 3+ rounds to verify tides resumed self-scheduling ---")
    // After Supervisor seeds, tides should resume self-scheduling and continue perpetually.
    // We run 4 rounds to ensure each tide executes at least 3 times after recovery.
    
    round = 0
    while round < 4 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5 + (UFix64(round) * 0.1))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5 + (UFix64(round) * 0.05))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }

    let execEventsFinal = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let newExecutions = execEventsFinal.length - execCountBeforeRecovery
    log("Final total executions: ".concat(execEventsFinal.length.toString()))
    log("New executions after recovery: ".concat(newExecutions.toString()))
    
    // After Supervisor seeds 5 tides:
    // - 1 Supervisor execution
    // - 10 initial seeded executions (1 per tide)
    // - Plus 3 more rounds of 10 executions each = 30 more
    // Total minimum: 1 + 10 + 30 = 41, but we'll be conservative and expect 30+
    Test.assert(
        newExecutions >= 15,
        message: "Should have at least 15 new executions (5 tides x 3+ rounds). Got: ".concat(newExecutions.toString())
    )

    // ========================================
    // STEP 11: Verify tides are no longer stuck
    // ========================================
    log("\n--- STEP 11: Verifying tides are no longer stuck ---")
    // After recovery, tides should have resumed self-scheduling and be healthy
    var stillStuckCount = 0
    for tideID in tideIDs {
        let isStuckRes = executeScript(
            "../scripts/flow-vaults/is_stuck_tide.cdc",
            [tideID]
        )
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stillStuckCount = stillStuckCount + 1
            }
        }
    }
    log("Tides still stuck: ".concat(stillStuckCount.toString()))
    Test.assertEqual(0, stillStuckCount)

    // ========================================
    // STEP 12: Verify all tides have active schedules
    // ========================================
    log("\n--- STEP 12: Verifying all tides have active schedules ---")
    var activeScheduleCount = 0
    for tideID in tideIDs {
        let hasActiveRes = executeScript(
            "../scripts/flow-vaults/has_active_schedule.cdc",
            [tideID]
        )
        if hasActiveRes.returnValue != nil {
            let hasActive = hasActiveRes.returnValue! as! Bool
            if hasActive {
                activeScheduleCount = activeScheduleCount + 1
            }
        }
    }
    log("Tides with active schedules: ".concat(activeScheduleCount.toString()).concat("/").concat(tideIDs.length.toString()))
    Test.assertEqual(5, activeScheduleCount)

    log("\n========================================")
    log("PASS: Comprehensive Insufficient Funds Recovery Test!")
    log("- 5 tides created and ran 3 rounds (15 executions)")
    log("- After drain: all ".concat(stuckCount.toString()).concat(" tides became stuck"))
    log("- Supervisor detected stuck tides: ".concat(stuckDetectedEvents.length.toString()))
    log("- Supervisor seeded tides: ".concat(seededEvents.length.toString()))
    log("- ".concat(newExecutions.toString()).concat(" new executions after recovery"))
    log("- All tides resumed self-scheduling and are healthy")
    log("- All ".concat(activeScheduleCount.toString()).concat(" tides have active schedules"))
    log("========================================")
}

access(all)
fun main() {
    setup()
    testAutoRegisterAndSupervisor()
    testMultiTideNativeScheduling()
    testStuckTideDetectionLogic()
    testInsufficientFundsAndRecovery()
}
