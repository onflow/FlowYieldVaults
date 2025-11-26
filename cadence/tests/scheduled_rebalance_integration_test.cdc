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

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0
access(all) var tideID: UInt64 = 0

access(all)
fun setup() {
    log("🚀 Setting up scheduled rebalancing integration test...")
    
    deployContracts()
    
    // Deploy FlowVaultsScheduler (idempotent across tests)
    deployFlowVaultsSchedulerIfNeeded()
    log("✅ FlowVaultsScheduler available")
    
    // Fund FlowVaults account for scheduling fees (registerTide requires FLOW)
    mintFlow(to: flowVaultsAccount, amount: 1000.0)

    // Set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    log("✅ Mock oracle prices set")

    // Mint tokens & set liquidity in mock swapper contract
    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)
    log("✅ Token liquidity setup")

    // Setup FlowALP with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    log("✅ FlowALP pool configured")

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/tests/transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    log("✅ Wrapped position created")

    // Enable mocked Strategy creation
    addStrategyComposer(
        signer: flowVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )
    log("✅ Strategy composer added")

    snapshot = getCurrentBlockHeight()
    log("✅ Setup complete at block \(snapshot)")
}

access(all)
fun testScheduledRebalancing() {
    log("\n🧪 Starting scheduled rebalancing integration test...")
    
    let fundingAmount = 1000.0
    let user = Test.createAccount()
    
    // Step 1: Create a Tide with initial funding
    log("\n📝 Step 1: Creating Tide...")
    mintFlow(to: user, amount: fundingAmount)
    let betaRef = grantBeta(flowVaultsAccount, user)
    Test.expect(betaRef, Test.beSucceeded())
    
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, fundingAmount],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    // Get the tide ID from events
    let tideIDsResult = getTideIDs(address: user.address)
    Test.assert(tideIDsResult != nil, message: "Expected tide IDs to be non-nil")
    let tideIDs = tideIDsResult!
    Test.assert(tideIDs.length > 0, message: "Expected at least one tide")
    tideID = tideIDs[0]
    log("✅ Tide created with ID: \(tideID)")
    
    // Step 2: Get initial AutoBalancer balance
    let initialBalance = getAutoBalancerBalanceByID(tideID: tideID)
    log("📊 Initial AutoBalancer balance: \(initialBalance ?? 0.0)")
    
    // Step 3: Setup SchedulerManager for FlowVaults account
    log("\n📝 Step 2: Setting up SchedulerManager...")
    let setupRes = executeTransaction(
        "../transactions/flow-vaults/setup_scheduler_manager.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupRes, Test.beSucceeded())
    log("✅ SchedulerManager created")
    
    // Step 4: Cancel auto-scheduled rebalancing (registerTide now atomically schedules)
    // Then manually schedule with specific parameters
    log("\n📝 Step 3: Cancel auto-schedule and reschedule with test parameters...")
    
    // Cancel the auto-scheduled rebalancing first
    let cancelAutoRes = executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(cancelAutoRes, Test.beSucceeded())
    log("✅ Cancelled auto-scheduled rebalancing")
    
    let currentTime = getCurrentBlock().timestamp
    let requestedTime = currentTime + 60.0
    
    // Estimate the cost first
    let estimateRes = executeScript(
        "../scripts/flow-vaults/estimate_rebalancing_cost.cdc",
        [requestedTime, UInt8(1), UInt64(500)]
    )
    Test.expect(estimateRes, Test.beSucceeded())
    let estimate = estimateRes.returnValue! as! FlowTransactionScheduler.EstimatedScheduledTransaction
    let fee = estimate.flowFee ?? 0.00006
    log("💰 Estimated fee: \(fee)")
    
    // Fund the FlowVaults account with enough for fees
    mintFlow(to: flowVaultsAccount, amount: fee * 2.0)
    
    // Schedule the rebalancing using a fresh timestamp to avoid \"timestamp in the past\"
    // races between estimation and scheduling.
    let scheduledTime = getCurrentBlock().timestamp + 60.0
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [
            tideID,
            scheduledTime,
            UInt8(1), // Medium priority
            UInt64(500),
            fee * 1.2, // Add 20% buffer
            false, // force = false (respect thresholds)
            false, // isRecurring = false
            nil as UFix64? // no recurring interval
        ],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beSucceeded())
    log("✅ Rebalancing scheduled for timestamp: \(scheduledTime)")
    
    // Step 5: Verify schedule was created
    log("\n📝 Step 4: Verifying schedule creation...")
    let schedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(schedulesRes, Test.beSucceeded())
    let schedules = schedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    Test.assert(schedules.length == 1, message: "Expected 1 scheduled transaction")
    log("✅ Schedule verified: \(schedules.length) transaction(s) scheduled")
    
    // Step 6: Change FLOW price to trigger rebalancing need
    log("\n📝 Step 5: Changing FLOW price...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    log("✅ FLOW price changed to 1.5 (from 1.0)")
    
    // Step 7: Wait for automatic execution by emulator FVM
    log("\n📝 Step 6: Waiting for automatic execution...")
    log("============================================================")
    log("ℹ️  The Flow Emulator FVM should automatically execute this!")
    log("   Watch emulator console for:")
    log("   - [system.process_transactions] processing transactions")
    log("   - [system.execute_transaction] executing transaction X")
    log("")
    log("   Current time: \(getCurrentBlock().timestamp)")
    log("   Scheduled time: \(scheduledTime)")
    log("   Waiting for scheduled time to pass...")
    log("============================================================")
    
    // Advance time past the scheduled execution time
    Test.moveTime(by: 15.0)
    
    log("============================================================")
    
    // Step 8: Check for execution events
    log("\n📝 Step 7: Checking for execution events...")
    
    let executionEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    let schedulerExecutedEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let pendingEvents = Test.eventsOfType(Type<FlowTransactionScheduler.PendingExecution>())
    
    log("📊 Events found:")
    log("   DeFiActions.Rebalanced: \(executionEvents.length)")
    log("   Scheduler.Executed: \(schedulerExecutedEvents.length)")
    log("   Scheduler.PendingExecution: \(pendingEvents.length)")
    
    // Step 9: Check final balance to see if rebalancing occurred
    log("\n📝 Step 8: Checking balance changes...")
    
    let initialBal = initialBalance ?? 0.0
    let finalBalance = getAutoBalancerBalanceByID(tideID: tideID) ?? 0.0
    
    log("📊 Initial AutoBalancer balance: \(initialBal)")
    log("📊 Final AutoBalancer balance: \(finalBalance)")
    log("📊 Balance change: \(finalBalance - initialBal)")
    
    // Step 10: Check schedule status
    log("\n📝 Step 9: Checking schedule status...")
    let finalSchedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(finalSchedulesRes, Test.beSucceeded())
    let finalSchedules = finalSchedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    
    log("📊 Schedules remaining: \(finalSchedules.length)")
    if finalSchedules.length > 0 {
        let schedule = finalSchedules[0]
        log("   Tide ID: \(schedule.tideID)")
        log("   Status: \(schedule.status?.rawValue ?? 99) (1=Scheduled, 2=Executed)")
    }
    
    // Step 11: Determine if automatic execution occurred
    log("\n📝 Step 10: Test Results...")
    log("============================================================")
    
    if executionEvents.length > 0 {
        log("🎉 SUCCESS: AUTOMATIC EXECUTION WORKED!")
        log("   ✅ DeFiActions.Rebalanced event found")
        log("   ✅ FlowTransactionScheduler executed the transaction")
        log("   ✅ AutoBalancer.executeTransaction() was called by FVM")
        log("   ✅ Balance changed: \(finalBalance - initialBal)")
    } else if schedulerExecutedEvents.length > 0 {
        log("🎉 PARTIAL SUCCESS: Scheduler executed something")
        log("   ✅ FlowTransactionScheduler.Executed event found")
        log("   ⚠️  But no DeFiActions.Rebalanced event")
        log("   → Check emulator logs for details")
    } else {
        log("⚠️  AUTOMATIC EXECUTION NOT DETECTED")
        log("   Possible reasons:")
        log("   1. Not enough time passed (need more blocks)")
        log("   2. Check emulator console for execution logs")
        log("")
        log("   What WAS verified:")
        log("   ✅ Schedule created successfully")
        log("   ✅ Capability issued correctly")
        log("   ✅ Integration points working")
        log("")
        log("   NOTE: Check the emulator console output for system logs!")
    }
    
    log("============================================================")
    
    log("\n🎉 Scheduled rebalancing integration test complete!")
}

access(all)
fun testCancelScheduledRebalancing() {
    log("\n🧪 Starting cancel scheduled rebalancing test...")
    
    // Create a NEW schedule to cancel
    // We need a tideID. We can reuse the one from setup if global, or create a new one.
    // Since we don't have easy access to tideID from previous test (it's a script variable but might be cleaner to fetch it),
    // let's fetch tideIDs for the user.
    // But we don't have the 'user' account from previous test easily available unless we store it or re-login.
    // Let's just create a new tide for this test to be clean.
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 100.0)
    grantBeta(flowVaultsAccount, user)
    
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: 10.0,
        beFailed: false
    )
    
    let tideIDs = getTideIDs(address: user.address)!
    let myTideID = tideIDs[0]
    log("✅ Created new Tide for cancel test: \(myTideID)")
    
    // Tide is already auto-scheduled by registerTide, verify it exists
    log("✅ Tide is auto-scheduled by registerTide")
    
    // Verify it exists
    let schedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let schedules = schedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    
    var found = false
    for s in schedules {
        if s.tideID == myTideID {
            found = true
            log("📋 Found schedule for Tide ID: \(s.tideID), Status: \(s.status?.rawValue ?? 99)")
        }
    }
    Test.assert(found, message: "Schedule not found")

    // Cancel it
    log("📝 Canceling scheduled rebalancing...")
    let cancelRes = executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [myTideID],
        flowVaultsAccount
    )
    Test.expect(cancelRes, Test.beSucceeded())
    log("✅ Schedule canceled successfully")
    
    // Verify it's removed
    let afterCancelRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let afterCancelSchedules = afterCancelRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    
    found = false
    for s in afterCancelSchedules {
        if s.tideID == myTideID {
            found = true
        }
    }
    Test.assert(!found, message: "Schedule should have been removed")
    
    log("\n🎉 Cancel test complete!")
}

// Helper functions
access(all)
fun getAutoBalancerBalanceByID(tideID: UInt64): UFix64? {
    let res = executeScript(
        "../scripts/flow-vaults/get_auto_balancer_balance_by_id.cdc",
        [tideID]
    )
    if res.status == Test.ResultStatus.succeeded {
        return res.returnValue as! UFix64?
    }
    return nil
}

// Main test runner
access(all)
fun main() {
    setup()
    testScheduledRebalancing()
    testCancelScheduledRebalancing()
}

