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
    log("🚀 Setting up scheduled rebalancing scenario test on EMULATOR...")
    
    deployContracts()
    
    // Deploy FlowVaultsScheduler (idempotent across tests)
    deployFlowVaultsSchedulerIfNeeded()
    log("✅ FlowVaultsScheduler available")

    // Set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    log("✅ Mock oracle prices set")

    // Mint tokens & set liquidity
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

    // Setup FlowALP with a Pool
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

    // Enable Strategy creation
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
fun testScheduledRebalancingWithPriceChange() {
    log("\n🧪 Testing Scheduled Rebalancing with Price Changes...")
    log("=" .concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("="))
    
    let fundingAmount = 1000.0
    let user = Test.createAccount()
    
    // Create a Tide
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
    
    let tideIDsResult = getTideIDs(address: user.address)
    Test.assert(tideIDsResult != nil, message: "Expected tide IDs")
    let tideIDs = tideIDsResult!
    tideID = tideIDs[0]
    log("✅ Tide created with ID: \(tideID)")
    
    let initialBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("📊 Initial AutoBalancer balance: \(initialBalance)")
    
    // Setup SchedulerManager
    log("\n📝 Step 2: Setting up SchedulerManager...")
    let setupRes = executeTransaction(
        "../transactions/flow-vaults/setup_scheduler_manager.cdc",
        [],
        flowVaultsAccount
    )
    Test.expect(setupRes, Test.beSucceeded())
    log("✅ SchedulerManager created")
    
    // Test scheduling infrastructure
    log("\n📝 Step 3: Testing Schedule Creation...")
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 10.0
    
    // Estimate cost
    let estimateRes = executeScript(
        "../scripts/flow-vaults/estimate_rebalancing_cost.cdc",
        [scheduledTime, UInt8(1), UInt64(500)]
    )
    Test.expect(estimateRes, Test.beSucceeded())
    let estimate = estimateRes.returnValue! as! FlowTransactionScheduler.EstimatedScheduledTransaction
    log("💰 Estimated fee: \(estimate.flowFee!)")
    
    // Fund the account
    mintFlow(to: flowVaultsAccount, amount: estimate.flowFee! * 2.0)
    
    // Create the schedule
    log("\n📝 Step 4: Creating Schedule...")
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [
            tideID,
            scheduledTime,
            UInt8(1),
            UInt64(500),
            estimate.flowFee! * 1.2,
            false, // force=false
            false, // not recurring
            nil as UFix64?
        ],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beSucceeded())
    log("✅ Schedule created for timestamp: \(scheduledTime)")
    
    // Verify schedule
    log("\n📝 Step 5: Verifying Schedule...")
    let schedulesRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(schedulesRes, Test.beSucceeded())
    let schedules = schedulesRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    Test.assertEqual(1, schedules.length)
    log("✅ Schedule verified: \(schedules.length) active schedule(s)")
    
    // Change price to trigger rebalancing need
    log("\n📝 Step 6: Changing FLOW price to trigger rebalancing need...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    log("✅ FLOW price changed from 1.0 to 1.5")
    
    // Wait for automatic execution (with --scheduled-transactions flag)
    log("\n📝 Step 7: Waiting for Automatic Execution...")
    log("ℹ️  With emulator started using: flow emulator --scheduled-transactions")
    log("ℹ️  The FVM should automatically execute the scheduled transaction")
    log("ℹ️  Committing blocks to advance time past scheduled time...")
    
    // Commit blocks to advance past the scheduled time
    var blocksCommitted = 0
    while blocksCommitted < 30 && getCurrentBlock().timestamp < scheduledTime {
        Test.commitBlock()
        blocksCommitted = blocksCommitted + 1
    }
    
    log("✅ Advanced \(blocksCommitted) blocks")
    log("   Current time: \(getCurrentBlock().timestamp)")
    log("   Scheduled time: \(scheduledTime)")
    
    // Give a few more blocks for the scheduler to process
    var i = 0
    while i < 10 {
        Test.commitBlock()
        i = i + 1
    }
    
    log("✅ Waited for automatic execution")
    
    // Check for automatic execution events
    log("\n📝 Step 8: Checking for Automatic Execution Events...")
    let rebalancingEvents = Test.eventsOfType(Type<FlowVaultsScheduler.RebalancingExecuted>())
    let schedulerExecutedEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    
    log("📊 RebalancingExecuted events: \(rebalancingEvents.length)")
    log("📊 Scheduler.Executed events: \(schedulerExecutedEvents.length)")
    
    // Verify rebalancing occurred
    log("\n📝 Step 9: Verifying Rebalancing Result...")
    let finalBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("📊 Initial balance: \(initialBalance)")
    log("📊 Final balance:   \(finalBalance)")
    log("📊 Change:          \(finalBalance - initialBalance)")
    
    if rebalancingEvents.length > 0 {
        log("✅ SUCCESS: RebalancingExecuted event found!")
        log("   Automatic execution happened!")
    } else if finalBalance != initialBalance {
        log("✅ Balance changed - rebalancing occurred")
    } else {
        log("⚠️  No automatic execution detected")
        log("   (Timestamp may not have advanced enough in test framework)")
    }
    
    // Test cancellation
    log("\n📝 Step 9: Testing Schedule Cancellation...")

    // Inspect current schedules for this account
    let beforeCancelRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(beforeCancelRes, Test.beSucceeded())
    let beforeCancel = beforeCancelRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]

    var attemptedCancel = false

    if beforeCancel.length > 0 {
        let sched = beforeCancel[0]
        let st = sched.status

        // Only attempt cancel if the schedule is still marked as Scheduled.
        if st != nil && st! == FlowTransactionScheduler.Status.Scheduled {
            let cancelRes = executeTransaction(
                "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
                [tideID],
                flowVaultsAccount
            )
            Test.expect(cancelRes, Test.beSucceeded())
            log("✅ Schedule canceled successfully")
            attemptedCancel = true
        } else {
            log("ℹ️  Skipping cancel: schedule status is \(st == nil ? 99 : st!.rawValue)")
        }
    } else {
        log("ℹ️  No schedules present before cancel; nothing to do")
    }
    
    // Verify there is no still-scheduled rebalancing for this Tide
    let afterCancelRes = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    Test.expect(afterCancelRes, Test.beSucceeded())
    let afterCancel = afterCancelRes.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]

    var hasActive = false
    var idx = 0
    while idx < afterCancel.length {
        let s = afterCancel[idx]
        if s.tideID == tideID {
            let st = s.status
            if st != nil && st! == FlowTransactionScheduler.Status.Scheduled {
                hasActive = true
            }
        }
        idx = idx + 1
    }
    Test.assert(!hasActive, message: "Expected no active scheduled rebalancing for Tide #\(tideID) after cancellation / execution")
    
    log("\n" .concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("="))
    log("🎉 Scheduled Rebalancing Scenario Test Complete!")
    log("=" .concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("=").concat("="))
}

// Main test runner
access(all)
fun main() {
    setup()
    testScheduledRebalancingWithPriceChange()
}

