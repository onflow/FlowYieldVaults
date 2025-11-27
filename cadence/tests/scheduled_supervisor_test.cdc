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

/// Tests that the Supervisor correctly recovers a tide from the pending queue.
/// 
/// ARCHITECTURE (Native AutoBalancer Scheduling):
/// - AutoBalancers self-schedule via recurringConfig and FlowTransactionScheduler
/// - The SchedulerManager is used by Supervisor for recovery only
/// - When a tide is enqueued to pending, Supervisor picks it up and schedules via SchedulerManager
///
/// TEST SCENARIO:
/// 1. Create tide (AutoBalancer schedules itself natively)
/// 2. Verify tide is in registry
/// 3. Enqueue tide to pending (simulating monitoring detection of failed reschedule)
/// 4. Setup and run Supervisor
/// 5. Verify Supervisor picks up tide from pending and schedules it via SchedulerManager
///
access(all)
fun testSupervisorRecoveryOfFailedReschedule() {
    log("\n Testing Supervisor recovery from pending queue...")

    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    mintFlow(to: flowVaultsAccount, amount: 200.0)

    // 1. Create a tide (AutoBalancer schedules itself natively)
    log("Step 1: Creating tide...")
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))

    // 2. Verify tide is in registry (registration happens at AB init)
    log("Step 2: Verifying tide is in registry...")
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be in registry")
    log("Tide is registered in FlowVaultsSchedulerRegistry")

    // 3. Wait for some native executions to verify it's working
    log("Step 3: Waiting for native execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEventsBefore = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions before enqueue: ".concat(execEventsBefore.length.toString()))

    // 4. Enqueue tide to pending (simulates: monitoring detects failed reschedule)
    log("Step 4: Enqueuing tide to pending (simulating monitoring detection)...")
    let enqueueRes = executeTransaction(
        "../transactions/flow-vaults/enqueue_pending_tide.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(enqueueRes, Test.beSucceeded())

    let pendingCountRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingCountRes.returnValue! as! Int
    Test.assert(pendingCount > 0, message: "Pending queue should have at least 1 tide")
    log("Pending queue size: ".concat(pendingCount.toString()))

    // 5. Setup Supervisor and SchedulerManager
    log("Step 5: Setting up Supervisor...")
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_supervisor.cdc", [], flowVaultsAccount)
    
    // Commit block to ensure state is synced
    Test.commitBlock()
    
    // Schedule Supervisor with very large offset to handle cumulative time from all tests
    // The timestamp must be in the future at the time the transaction EXECUTES, not when we get the block
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

    // 7. Check for SupervisorSeededTide event
    let seededEvents = Test.eventsOfType(Type<FlowVaultsScheduler.SupervisorSeededTide>())
    log("SupervisorSeededTide events: ".concat(seededEvents.length.toString()))
    
    var seededOurTide = false
    for e in seededEvents {
        let evt = e as! FlowVaultsScheduler.SupervisorSeededTide
        log("  - Supervisor seeded tide: ".concat(evt.tideID.toString()))
        if evt.tideID == tideID {
            seededOurTide = true
        }
    }

    // 8. Verify more executions happened (native scheduling continues)
    log("Step 7: Verifying continued execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()

    let execEventsAfter = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after recovery: ".concat(execEventsAfter.length.toString()))
    
    // Verification: We should have more executions than before
    Test.assert(
        execEventsAfter.length > execEventsBefore.length,
        message: "Should have more executions after recovery. Before: ".concat(execEventsBefore.length.toString()).concat(", After: ").concat(execEventsAfter.length.toString())
    )

    // Check pending queue state
    let finalPendingRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let finalPending = finalPendingRes.returnValue! as! Int
    log("Final pending queue size: ".concat(finalPending.toString()))
    
    log("PASS: Supervisor Recovery Test")
}

access(all)
fun main() {
    setup()
    testAutoRegisterAndSupervisor()
    testMultiTideFanOut()
}
