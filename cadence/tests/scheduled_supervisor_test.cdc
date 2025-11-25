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

access(all)
fun testAutoRegisterAndSupervisor() {
    log("\n🧪 Testing Auto-Register + Supervisor...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // 1. Create Tide (Should auto-register)
    log("📝 Step 1: Create Tide")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("✅ Tide created: \(tideID)")

    // Verify registration
    let regIDsRes = executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    )
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be registered")
    log("✅ Tide is registered")

    // 2. Setup SchedulerManager and Supervisor
    log("📝 Step 2: Setup Scheduler & Supervisor")
    let setupMgrRes = executeTransaction(
        "../transactions/flow-vaults/setup_scheduler_manager.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupMgrRes, Test.beSucceeded())

    let setupSupRes = executeTransaction(
        "../transactions/flow-vaults/setup_supervisor.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupSupRes, Test.beSucceeded())

    // 3. Schedule Supervisor
    log("📝 Step 3: Schedule Supervisor")
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 60.0
    
    // Estimate cost for Supervisor (it pays for children too)
    mintFlow(to: flowVaultsAccount, amount: 100.0) // abundant funding

    let scheduleSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [
            scheduledTime,
            UInt8(1),
            UInt64(800),
            0.01, // fee
            5.0, // recurringInterval (Supervisor interval)
            true, // childRecurring
            5.0, // childInterval (per-tide interval)
            false // force
        ],
        flowVaultsAccount
    )
    Test.expect(scheduleSupRes, Test.beSucceeded())
    log("✅ Supervisor scheduled")

    // 4. Wait for Supervisor Execution
    log("📝 Step 4: Wait for Supervisor to seed child")
    // Supervisor was scheduled ~60 seconds in the future; advance past that.
    Test.moveTime(by: 75.0)
    Test.commitBlock()

    // Check if Supervisor executed
    // Supervisor seeding doesn't emit a specific event, but it schedules a child.
    
    let childSchedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let childSchedules = childSchedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    
    var childFound = false
    for s in childSchedules {
        if s.tideID == tideID {
            childFound = true
            log("✅ Child schedule found for Tide \(tideID)")
        }
    }
    Test.assert(childFound, message: "Supervisor should have seeded child schedule")

    // 5. Induce Drift and Wait for Child Execution
    log("📝 Step 5: Induce Drift & Wait for Child")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)

    // The child was scheduled by Supervisor with lookahead.
    // Supervisor ran at T+15 (approx). Lookahead was 5. So Child is at T+20.
    Test.moveTime(by: 15.0) // Move another 15s
    Test.commitBlock()

    // 6. Verify Execution
    log("📝 Step 6: Verify Execution")
    let execEvents = Test.eventsOfType(Type<FlowVaultsScheduler.RebalancingExecuted>())
    Test.assert(execEvents.length > 0, message: "Should have RebalancingExecuted event")
    
    // Verify Status
    let executedRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    
    log("🎉 Auto-Register + Supervisor Test Passed")
}

access(all)
fun testMultiTideFanOut() {
    log("\n🧪 Testing Multi-Tide Fan-Out...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 3 tides manually
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
    log("📝 Created tides")
    log(allTides)

    // Reset Scheduler Manager to clear previous state
    executeTransaction("../transactions/flow-vaults/reset_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 10.0
    
    executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [scheduledTime, UInt8(1), UInt64(800), 0.01, 5.0, true, 5.0, false],
        flowVaultsAccount
    )
    
    Test.moveTime(by: 15.0)
    Test.commitBlock()
    
    let childSchedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let childSchedules = childSchedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    
    var scheduledCount = 0
    for tideID in allTides {
        for s in childSchedules {
            if s.tideID == tideID {
                scheduledCount = scheduledCount + 1
                break
            }
        }
    }
    
    // We expect at least the 3 new tides to be scheduled.
    Test.assert(scheduledCount >= 3, message: "All new tides should be scheduled by Supervisor")
    log("✅ All \(scheduledCount) tides scheduled")
    
    log("🎉 Multi-Tide Fan-Out Test Passed")
}

/// Verifies that once a Tide has been seeded with a recurring child schedule,
/// its rebalancing handler is actually executed (not just scheduled) and that
/// the recurring configuration remains in place. Due to current emulator
/// scheduler behavior we reliably observe at least one execution in tests.
access(all)
fun testRecurringRebalancingThreeRuns() {
    log("\n🧪 Testing recurring rebalancing executes at least three times...")

    // Fresh user + beta access
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)

    // 1. Create Tide (auto-registers with scheduler/registry)
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())

    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("✅ Tide created for recurring test: ".concat(tideID.toString()))

    // 2. Setup SchedulerManager and Supervisor
    let setupMgrRes = executeTransaction(
        "../transactions/flow-vaults/setup_scheduler_manager.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupMgrRes, Test.beSucceeded())

    let setupSupRes = executeTransaction(
        "../transactions/flow-vaults/setup_supervisor.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupSupRes, Test.beSucceeded())

    // Ensure FlowVaults account has sufficient FLOW to fund Supervisor + 3+ child runs
    mintFlow(to: flowVaultsAccount, amount: 100.0)

    // 3. Schedule Supervisor soon, with a short child interval so multiple runs fit in the test window.
    // IMPORTANT: Use a large offset (300s) to handle CI timing variability. The test framework
    // may advance block timestamps unpredictably between getCurrentBlock() and the actual
    // schedule transaction execution, especially in slower CI environments.
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 300.0

    let scheduleSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [
            scheduledTime,
            UInt8(1),     // Medium priority
            UInt64(800),  // executionEffort
            0.05,         // initial fee for Supervisor
            300.0,        // Supervisor recurring interval (large; we only need first run)
            true,         // childRecurring
            5.0,          // childInterval (seconds between child runs)
            true          // force children to rebalance to avoid threshold-related no-ops
        ],
        flowVaultsAccount
    )
    Test.expect(scheduleSupRes, Test.beSucceeded())
    log("✅ Supervisor scheduled for recurring test")

    // 4. Drive time forward stepwise so that:
    //    - First, Supervisor executes once.
    //    - Then, the recurring child job executes multiple times.
    //
    //    We don't know the exact internal timestamp used by the scheduler, but
    //    we can advance in conservative increments that are comfortably larger
    //    than the configured lookahead / childInterval.

    // 4a. Ensure Supervisor executes (scheduled at ~currentTime+300 above).
    Test.moveTime(by: 310.0)
    Test.commitBlock()

    // 4b. Now advance time in several separate steps that are each longer than
    //     childInterval (5.0), allowing the recurring child job to execute
    //     at least once, and giving the scheduler room to schedule follow-ups.
    var i = 0
    var count = 0
    var lastExecutedID: UInt64 = 0
    while i < 10 && count < 3 {
        Test.moveTime(by: 10.0)
        Test.commitBlock()
        i = i + 1

        // 5. Count wrapper-level executions for this Tide and require at least one.
        let execEvents = Test.eventsOfType(Type<FlowVaultsScheduler.RebalancingExecuted>())
        count = 0
        for e in execEvents {
            let evt = e as! FlowVaultsScheduler.RebalancingExecuted
            if evt.tideID == tideID {
                count = count + 1
                lastExecutedID = evt.scheduledTransactionID
            }
        }
    }

    Test.assert(
        count >= 3,
        message: "Expected at least 3 RebalancingExecuted events for Tide ".concat(tideID.toString()).concat(" but found ").concat(count.toString())
    )
    log("🎉 Recurring rebalancing executed \(count) time(s) for Tide ".concat(tideID.toString()))

    // 6. After the latest observed execution, ensure that a *new* recurring
    //    schedule exists for this Tide (i.e. scheduleNextIfRecurring has
    //    chained the next job).
    let schedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(schedulesRes, Test.beSucceeded())
    let schedules = schedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]

    var nextFound = false
    for s in schedules {
        if s.tideID == tideID && s.isRecurring && s.recurringInterval != nil && s.recurringInterval! > 0.0 {
            // The current scheduled tx for this tide should be a *different*
            // ID than the one we just saw execute.
            Test.assert(
                s.scheduledTransactionID != lastExecutedID,
                message: "Expected new scheduledTransactionID for recurring Tide but found same ID as executed"
            )
            nextFound = true
        }
    }

    Test.assert(
        nextFound,
        message: "Expected a recurring scheduled rebalancing entry for Tide ".concat(tideID.toString()).concat(" after execution")
    )
    log("✅ Verified that next recurring rebalancing is scheduled for Tide ".concat(tideID.toString()))
}

access(all)
fun main() {
    setup()
    testAutoRegisterAndSupervisor()
    testMultiTideFanOut()
}
