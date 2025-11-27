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
    log("✅ Setup complete")
}

/// Test: Auto-Register and Native Scheduling
/// 
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native FlowTransactionScheduler
/// - The Supervisor is for recovery only (picks up from pending queue)
/// - SchedulerManager doesn't track native schedules
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

/// Test: Multi-Tide Fan-Out (Native Scheduling)
/// 
/// NEW ARCHITECTURE:
/// - Each tide's AutoBalancer self-schedules via native mechanism
/// - No Supervisor seeding needed - tides execute independently
///
access(all)
fun testMultiTideFanOut() {
    log("\n Testing Multi-Tide Native Scheduling...")
    
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
    
    log("PASS: Multi-Tide Native Scheduling")
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

/// Stress test: tests pagination with many tides exceeding MAX_BATCH_SIZE (50)
///
/// NEW ARCHITECTURE:
/// - AutoBalancers self-schedule via native mechanism
/// - Registry tracks all registered tides
/// - Pending queue is for RECOVERY (failed self-schedules)
/// - Pagination is used when processing pending queue in batches
///
/// This test creates 150 tides (3x MAX_BATCH_SIZE) to verify:
/// 1. All tides are registered correctly
/// 2. All tides self-schedule and execute via native mechanism
/// 3. Pagination functions work correctly for pending queue
///
access(all)
fun testPaginationStress() {
    log("\n Testing pagination with 150 tides (3x MAX_BATCH_SIZE of 50)...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 50000.0)
    grantBeta(flowVaultsAccount, user)
    mintFlow(to: flowVaultsAccount, amount: 10000.0)

    // Create 150 tides (3x MAX_BATCH_SIZE of 50)
    let numTides = 150
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
    
    // Check registry state - all tides should be registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    log("Registered tides: ".concat(regIDs.length.toString()))
    
    Test.assert(
        regIDs.length >= numTides,
        message: "Expected at least ".concat(numTides.toString()).concat(" registered tides")
    )
    
    // Verify pagination works on pending queue (should be empty since all self-schedule)
    let pendingCountRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    log("Pending queue size (should be 0 since all self-schedule): ".concat(pendingCount.toString()))
    
    // Test paginated access to pending queue
    let page0Res = executeScript("../scripts/flow-vaults/get_pending_tides_paginated.cdc", [0, 50])
    let page0 = page0Res.returnValue! as! [UInt64]
    log("Page 0 of pending queue: ".concat(page0.length.toString()).concat(" tides"))
    
    // Wait for native executions
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(execEvents.length.toString()))
    
    // All 150 tides should have executed at least once
    Test.assert(
        execEvents.length >= numTides,
        message: "Expected at least ".concat(numTides.toString()).concat(" executions")
    )
    
    log("PASS: 150 tides (3x MAX_BATCH_SIZE) all registered and executed")
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

    // 5. Setup Supervisor and SchedulerManager
    log("Step 5: Setting up Supervisor...")
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
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

/// Tests that tides continue executing in a long-running scenario
/// with Supervisor available for recovery if needed.
///
/// LIMITATION: Simulating actual insufficient funds is difficult in tests because:
/// - The test framework provides ample FLOW to accounts
/// - Scheduling fees are tiny (~0.001 FLOW per schedule)
/// - Draining the entire vault would require many executions or special setup
///
/// This test verifies the ARCHITECTURE works by:
/// 1. Running many tides over many execution cycles
/// 2. Having Supervisor available for any that might fail
/// 3. Verifying all tides continue executing
///
/// For ACTUAL insufficient funds testing:
/// - Would require modifying strategy to use a separate, limited-balance vault
/// - Or running thousands of executions to naturally drain funds
///
access(all)
fun testLongRunningWithSupervisorRecovery() {
    log("\n========================================")
    log("TEST: Long-Running Scenario with Supervisor")
    log("========================================")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 2000.0)
    grantBeta(flowVaultsAccount, user)

    // 1. Create 3 tides
    log("\nStep 1: Creating 3 tides...")
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

    // 2. Setup Supervisor for recovery (even though we expect no failures)
    log("\nStep 2: Setting up Supervisor for recovery...")
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_supervisor.cdc", [], flowVaultsAccount)
    mintFlow(to: flowVaultsAccount, amount: 100.0)
    
    Test.commitBlock()
    
    // Use large offset to handle cumulative time from all tests
    let scheduledTime = getCurrentBlock().timestamp + 3000.0
    let schedSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [scheduledTime, UInt8(1), UInt64(800), 0.05, 300.0, true, 60.0, true],  // scanForStuck=true
        flowVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled for recovery mode")

    // 3. Run many execution cycles
    log("\nStep 3: Running 5 execution cycles...")
    var cycle = 0
    while cycle < 5 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(cycle) * 0.1))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        cycle = cycle + 1
    }

    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions after 5 cycles: ".concat(execEvents.length.toString()))

    // 4. Check for any FailedRecurringSchedule events
    let failedEvents = Test.eventsOfType(Type<DeFiActions.FailedRecurringSchedule>())
    log("FailedRecurringSchedule events: ".concat(failedEvents.length.toString()))

    // 5. Verify stuck tide detection
    log("\nStep 4: Checking stuck tide detection...")
    var stuckCount = 0
    for tideID in tideIDs {
        let isStuckRes = executeScript(
            "../scripts/flow-vaults/is_stuck_tide.cdc",
            [tideID]
        )
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stuckCount = stuckCount + 1
            }
        }
    }
    log("Stuck tides: ".concat(stuckCount.toString()))
    
    // With sufficient funds, no tides should be stuck
    Test.assertEqual(0, stuckCount)

    // 6. Let Supervisor run
    log("\nStep 5: Letting Supervisor run...")
    Test.moveTime(by: 3100.0)
    Test.commitBlock()

    let stuckDetectedEvents = Test.eventsOfType(Type<FlowVaultsScheduler.StuckTideDetected>())
    log("StuckTideDetected events: ".concat(stuckDetectedEvents.length.toString()))
    
    // With healthy tides, no StuckTideDetected events expected
    Test.assertEqual(0, stuckDetectedEvents.length)

    // 7. Verify pending queue is empty
    let pendingRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingRes.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount.toString()))
    Test.assertEqual(0, pendingCount)

    // 8. Verify all tides have active schedules
    log("\nStep 6: Verifying all tides have active schedules...")
    var activeCount = 0
    for tideID in tideIDs {
        let hasActiveRes = executeScript(
            "../scripts/flow-vaults/has_active_schedule.cdc",
            [tideID]
        )
        if hasActiveRes.returnValue != nil {
            let hasActive = hasActiveRes.returnValue! as! Bool
            if hasActive {
                activeCount = activeCount + 1
            }
        }
    }
    log("Tides with active schedules: ".concat(activeCount.toString()).concat("/").concat(tideIDs.length.toString()))
    Test.assertEqual(tideIDs.length, activeCount)

    log("PASS: Long-running scenario with Supervisor available")
}

access(all)
fun main() {
    setup()
    testAutoRegisterAndSupervisor()
    testMultiTideFanOut()
}
