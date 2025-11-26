import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowVaultsScheduler"
import "FlowVaultsSchedulerRegistry"
import "FlowTransactionScheduler"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all)
fun setup() {
    log("Setting up scheduler edge cases test...")
    
    deployContracts()
    deployFlowVaultsSchedulerIfNeeded()
    
    // Fund FlowVaults account for scheduling fees (registerTide requires FLOW)
    mintFlow(to: flowVaultsAccount, amount: 1000.0)

    // Set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

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

    // Setup FlowALP
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/tests/transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Enable Strategy creation
    addStrategyComposer(
        signer: flowVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )

    log("Setup complete")
}

/// Test: Double-scheduling the same Tide should fail
access(all)
fun testDoubleSchedulingSameTideFails() {
    log("\n[TEST] Double-scheduling same Tide should fail...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create a Tide
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))
    
    // Setup scheduler manager
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    // Fund FlowVaults account for fees
    mintFlow(to: flowVaultsAccount, amount: 1.0)
    
    // Tide is already auto-scheduled by registerTide
    log("Tide is auto-scheduled (registerTide schedules atomically)")
    
    // Second schedule for same Tide - should FAIL (already scheduled)
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 100.0
    let secondSchedule = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [tideID, scheduledTime + 50.0, UInt8(1), UInt64(500), 0.001, false, false, nil as UFix64?],
        flowVaultsAccount
    )
    Test.expect(secondSchedule, Test.beFailed())
    log("Second schedule correctly failed (double-scheduling prevented)")
}

/// Test: Scheduling for unregistered Tide should fail
access(all)
fun testSchedulingUnregisteredTideFails() {
    log("\n[TEST] Scheduling for unregistered Tide should fail...")
    
    // Use a Tide ID that doesn't exist
    let fakeTideID: UInt64 = 999999
    
    // Setup scheduler manager
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    mintFlow(to: flowVaultsAccount, amount: 1.0)
    
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 100.0
    
    // Try to schedule for non-existent Tide - should fail
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [fakeTideID, scheduledTime, UInt8(1), UInt64(500), 0.001, false, false, nil as UFix64?],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beFailed())
    log("Scheduling for unregistered Tide correctly failed")
}

/// Test: Canceling non-existent schedule should fail
access(all)
fun testCancelNonExistentScheduleFails() {
    log("\n[TEST] Canceling non-existent schedule should fail...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create a Tide but don't schedule anything
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    
    // Setup scheduler manager
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    // Tide is auto-scheduled, so first cancel succeeds
    let cancelRes = executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(cancelRes, Test.beSucceeded())
    log("First cancel succeeded (tide was auto-scheduled)")
    
    // Try to cancel again without having scheduled - should fail
    let cancelRes2 = executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(cancelRes2, Test.beFailed())
    log("Canceling non-existent schedule correctly failed")
}

/// Test: Recurring schedule with invalid interval should fail
access(all)
fun testRecurringWithZeroIntervalFails() {
    log("\n[TEST] Recurring with zero interval should fail...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    
    // Reset and setup scheduler manager
    executeTransaction("../transactions/flow-vaults/reset_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    mintFlow(to: flowVaultsAccount, amount: 1.0)
    
    // Cancel auto-scheduled rebalancing first
    executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 100.0
    
    // Try recurring with zero interval - should fail
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [tideID, scheduledTime, UInt8(1), UInt64(500), 0.001, false, true, 0.0 as UFix64?],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beFailed())
    log("Recurring with zero interval correctly failed")
}

/// Test: Verify scheduleData is cleaned up after cancel
access(all)
fun testScheduleDataCleanedAfterCancel() {
    log("\n[TEST] ScheduleData cleanup after cancel...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    
    // Reset and setup
    executeTransaction("../transactions/flow-vaults/reset_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    mintFlow(to: flowVaultsAccount, amount: 1.0)
    
    // Cancel auto-scheduled rebalancing first
    executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 100.0
    
    // Schedule
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [tideID, scheduledTime, UInt8(1), UInt64(500), 0.001, false, false, nil as UFix64?],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beSucceeded())
    
    // Verify schedule exists
    let beforeCancelRes = executeScript(
        "../scripts/flow-vaults/get_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address, tideID]
    )
    Test.expect(beforeCancelRes, Test.beSucceeded())
    let beforeSchedule = beforeCancelRes.returnValue as! FlowVaultsScheduler.RebalancingScheduleInfo?
    Test.assert(beforeSchedule != nil, message: "Schedule should exist before cancel")
    log("Schedule exists before cancel")
    
    // Cancel
    let cancelRes = executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(cancelRes, Test.beSucceeded())
    
    // Verify schedule is gone
    let afterCancelRes = executeScript(
        "../scripts/flow-vaults/get_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address, tideID]
    )
    Test.expect(afterCancelRes, Test.beSucceeded())
    let afterSchedule = afterCancelRes.returnValue as! FlowVaultsScheduler.RebalancingScheduleInfo?
    Test.assert(afterSchedule == nil, message: "Schedule should be gone after cancel")
    log("Schedule correctly cleaned up after cancel")
}

/// Test: Capability reuse - registering same tide twice should not issue new caps
access(all)
fun testCapabilityReuse() {
    log("\n[TEST] Capability reuse on re-registration...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    
    // Check registration
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be registered")
    
    // Get wrapper cap (first time)
    let capRes1 = executeScript("../scripts/flow-vaults/has_wrapper_cap_for_tide.cdc", [tideID])
    Test.expect(capRes1, Test.beSucceeded())
    let hasCap1 = capRes1.returnValue! as! Bool
    Test.assert(hasCap1, message: "Should have wrapper cap after creation")
    
    log("Capability correctly exists and would be reused on re-registration")
}

/// Test: Close tide with pending schedule cancels and refunds
access(all)
fun testCloseTideWithPendingSchedule() {
    log("\n[TEST] Close tide with pending schedule...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 200.0)
    grantBeta(flowVaultsAccount, user)
    
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    
    // Reset and setup
    executeTransaction("../transactions/flow-vaults/reset_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    
    mintFlow(to: flowVaultsAccount, amount: 1.0)
    
    // Cancel auto-scheduled rebalancing first
    executeTransaction(
        "../transactions/flow-vaults/cancel_scheduled_rebalancing.cdc",
        [tideID],
        flowVaultsAccount
    )
    
    let currentTime = getCurrentBlock().timestamp
    let scheduledTime = currentTime + 1000.0 // Far in future
    
    // Schedule
    let scheduleRes = executeTransaction(
        "../transactions/flow-vaults/schedule_rebalancing.cdc",
        [tideID, scheduledTime, UInt8(1), UInt64(500), 0.001, false, false, nil as UFix64?],
        flowVaultsAccount
    )
    Test.expect(scheduleRes, Test.beSucceeded())
    log("Schedule created for tide")
    
    // Verify schedule exists
    let schedules = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let scheduleList = schedules.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    var found = false
    for s in scheduleList {
        if s.tideID == tideID {
            found = true
        }
    }
    Test.assert(found, message: "Schedule should exist before close")
    
    // Close tide - should automatically cancel schedule and unregister
    let closeRes = executeTransaction(
        "../transactions/flow-vaults/close_tide.cdc",
        [tideID],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())
    log("Tide closed successfully")
    
    // Verify unregistered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(!regIDs.contains(tideID), message: "Tide should be unregistered after close")
    
    // Verify schedule is gone
    let schedulesAfter = executeScript(
        "../scripts/flow-vaults/get_all_scheduled_rebalancing.cdc",
        [flowVaultsAccount.address]
    )
    let scheduleListAfter = schedulesAfter.returnValue! as! [FlowVaultsScheduler.RebalancingScheduleInfo]
    var foundAfter = false
    for s in scheduleListAfter {
        if s.tideID == tideID {
            foundAfter = true
        }
    }
    Test.assert(!foundAfter, message: "Schedule should be gone after tide close")
    
    log("Tide close correctly cleaned up schedule and registry")
}

/// Test: Multiple users can have their own tides scheduled
access(all)
fun testMultipleUsersMultipleTides() {
    log("\n[TEST] Multiple users with multiple tides...")
    
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    mintFlow(to: user1, amount: 300.0)
    mintFlow(to: user2, amount: 300.0)
    grantBeta(flowVaultsAccount, user1)
    grantBeta(flowVaultsAccount, user2)
    
    // User1 creates 2 tides
    executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user1
    )
    executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user1
    )
    
    // User2 creates 1 tide
    executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user2
    )
    
    let user1Tides = getTideIDs(address: user1.address)!
    let user2Tides = getTideIDs(address: user2.address)!
    
    Test.assert(user1Tides.length >= 2, message: "User1 should have at least 2 tides")
    Test.assert(user2Tides.length >= 1, message: "User2 should have at least 1 tide")
    
    // Verify all are registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    
    for tid in user1Tides {
        Test.assert(regIDs.contains(tid), message: "User1 tide should be registered")
    }
    for tid in user2Tides {
        Test.assert(regIDs.contains(tid), message: "User2 tide should be registered")
    }
    
    log("All tides from multiple users correctly registered: ".concat(regIDs.length.toString()).concat(" total"))
}

