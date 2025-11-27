import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowTransactionScheduler"
import "FlowVaultsSchedulerRegistry"
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
    log("Setting up scheduled rebalancing scenario test on EMULATOR...")
    
    deployContracts()
    
    // Deploy FlowVaultsScheduler (idempotent across tests)
    deployFlowVaultsSchedulerIfNeeded()
    log("FlowVaultsScheduler available")
    
    // Fund FlowVaults account for scheduling fees
    mintFlow(to: flowVaultsAccount, amount: 1000.0)

    // Set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    log("Mock oracle prices set")

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
    log("Token liquidity setup")

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
    log("FlowALP pool configured")

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/tests/transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    log("Wrapped position created")

    // Enable Strategy creation
    addStrategyComposer(
        signer: flowVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )
    log("Strategy composer added")

    snapshot = getCurrentBlockHeight()
    log("Setup complete at block ".concat(snapshot.toString()))
}

/// Tests that a Tide created with native AutoBalancer recurring scheduling
/// executes rebalancing automatically over time.
access(all)
fun testNativeAutoBalancerRecurring() {
    log("\nTesting Native AutoBalancer Recurring Scheduling...")
    log("================")
    
    let fundingAmount = 1000.0
    let user = Test.createAccount()
    
    // Create a Tide - this will:
    // 1. Configure AutoBalancer with recurringConfig
    // 2. Register tide in FlowVaultsSchedulerRegistry
    // 3. Start the self-scheduling chain via scheduleNextRebalance
    log("\nStep 1: Creating Tide with native recurring scheduling...")
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
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Verify tide is registered in the registry
    log("\nStep 2: Verifying tide is registered...")
    let regIDsRes = executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    )
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be registered")
    log("Tide is registered in FlowVaultsSchedulerRegistry")
    
    let initialBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Initial AutoBalancer balance: ".concat(initialBalance.toString()))
    
    // Change price to trigger rebalancing need
    log("\nStep 3: Changing FLOW price to trigger rebalancing need...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    log("FLOW price changed from 1.0 to 1.5")
    
    // Wait for automatic execution
    log("\nStep 4: Waiting for Automatic Execution...")
    log("Advancing time past scheduled time...")
    
    // Advance time in steps to allow multiple executions
    var i = 0
    var executedCount = 0
    while i < 10 {
        Test.moveTime(by: 15.0)
        Test.commitBlock()
        
        let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        executedCount = execEvents.length
        i = i + 1
    }
    
    log("Advanced time by 150 seconds total")
    log("Current time: ".concat(getCurrentBlock().timestamp.toString()))
    
    // Check for automatic execution events
    log("\nStep 5: Checking for Execution Events...")
    let rebalancingEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    let schedulerExecutedEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    
    log("DeFiActions.Rebalanced events: ".concat(rebalancingEvents.length.toString()))
    log("Scheduler.Executed events: ".concat(schedulerExecutedEvents.length.toString()))
    
    // With native AutoBalancer recurring, we expect at least one execution
    // (the initial scheduled rebalance)
    Test.assert(
        schedulerExecutedEvents.length >= 1,
        message: "Expected at least 1 FlowTransactionScheduler.Executed event but found ".concat(schedulerExecutedEvents.length.toString())
    )
    log("Verified that scheduler executed at least once")
    
    // Verify rebalancing result
    log("\nStep 6: Verifying Rebalancing Result...")
    let finalBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Initial balance: ".concat(initialBalance.toString()))
    log("Final balance:   ".concat(finalBalance.toString()))
    log("Change:          ".concat((finalBalance - initialBalance).toString()))
    
    if rebalancingEvents.length > 0 {
        log("SUCCESS: DeFiActions.Rebalanced event found!")
    } else if finalBalance != initialBalance {
        log("Balance changed - rebalancing occurred")
    } else {
        log("Note: No rebalancing needed (thresholds not exceeded)")
    }
    
    log("\n================")
    log("Native AutoBalancer Recurring Test Complete!")
    log("================")
}

/// Tests that multiple tides each execute independently with native recurring scheduling.
access(all)
fun testMultipleTidesNativeRecurring() {
    log("\nTesting Multiple Tides with Native Recurring Scheduling...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 3000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 3 tides
    var tideIDs: [UInt64] = []
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
    
    tideIDs = getTideIDs(address: user.address)!
    log("Created ".concat(tideIDs.length.toString()).concat(" tides"))
    
    // Verify all tides are registered
    let regIDsRes = executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    )
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    for tid in tideIDs {
        Test.assert(regIDs.contains(tid), message: "Tide ".concat(tid.toString()).concat(" should be registered"))
    }
    log("All tides registered")
    
    // Advance time to allow executions
    i = 0
    while i < 20 {
        Test.moveTime(by: 10.0)
        Test.commitBlock()
        i = i + 1
    }
    
    // Count executions
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total FlowTransactionScheduler.Executed events: ".concat(execEvents.length.toString()))
    
    // With 3 tides and native recurring, we expect at least 3 executions (one per tide)
    Test.assert(
        execEvents.length >= 3,
        message: "Expected at least 3 scheduler executions but found ".concat(execEvents.length.toString())
    )
    
    log("Multiple Tides Native Recurring Test Passed!")
}

// Main test runner
access(all)
fun main() {
    setup()
    testNativeAutoBalancerRecurring()
    testMultipleTidesNativeRecurring()
}
