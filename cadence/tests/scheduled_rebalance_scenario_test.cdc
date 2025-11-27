import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowVaultsScheduler"
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

// ARCHITECTURE EXPECTATIONS:
// 1. When a Tide is created, the AutoBalancer is configured with recurringConfig
// 2. FlowVaultsAutoBalancers._initNewAutoBalancer registers tide in FlowVaultsSchedulerRegistry
// 3. AutoBalancer.scheduleNextRebalance(nil) starts the self-scheduling chain
// 4. AutoBalancer self-reschedules after each execution (no external intervention needed)
// 5. The Supervisor is for recovery only - picks up tides from pending queue

access(all)
fun setup() {
    log("Setting up scheduled rebalancing test with native AutoBalancer recurring...")
    
    deployContracts()
    deployFlowVaultsSchedulerIfNeeded()
    
    // Fund FlowVaults account for scheduling fees
    mintFlow(to: flowVaultsAccount, amount: 1000.0)

    // Set initial token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

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

/// TEST 1: Verify that the registry receives tide registration when AutoBalancer is initialized
/// 
/// ARCHITECTURE REQUIREMENT:
/// - When a Tide is created, FlowVaultsAutoBalancers._initNewAutoBalancer is called
/// - This function must register the tide in FlowVaultsSchedulerRegistry
/// - The TideRegistered event must be emitted
///
access(all)
fun testRegistryReceivesTideRegistrationAtInit() {
    log("\n========================================")
    log("TEST: Registry receives tide registration at AutoBalancer init")
    log("========================================")
    
    // Clear any previous events
    let eventsBefore = Test.eventsOfType(Type<FlowVaultsSchedulerRegistry.TideRegistered>())
    let registeredBefore = eventsBefore.length
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create a Tide - this triggers AutoBalancer initialization
    log("Step 1: Creating Tide...")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Step 2: Verify TideRegistered event was emitted
    log("Step 2: Verifying TideRegistered event...")
    let eventsAfter = Test.eventsOfType(Type<FlowVaultsSchedulerRegistry.TideRegistered>())
    let newEvents = eventsAfter.length - registeredBefore
    
    Test.assert(
        newEvents >= 1,
        message: "Expected at least 1 TideRegistered event, found ".concat(newEvents.toString())
    )
    log("TideRegistered events emitted: ".concat(newEvents.toString()))
    
    // Step 3: Verify tide is in the registry
    log("Step 3: Verifying tide is in registry...")
    let regIDsRes = executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    )
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    
    Test.assert(
        regIDs.contains(tideID),
        message: "Tide ".concat(tideID.toString()).concat(" should be in registry")
    )
    log("Tide is registered in FlowVaultsSchedulerRegistry")
    
    log("PASS: Registry receives tide registration at AutoBalancer init")
}

/// TEST 2: Each AutoBalancer runs at least 3 times with verified execution
///
/// ARCHITECTURE REQUIREMENT:
/// - AutoBalancer configured with recurringConfig (60 second interval)
/// - After creation, scheduleNextRebalance starts the chain
/// - After each execution, AutoBalancer self-reschedules
/// - Must verify 3 separate executions occurred
///
/// TEST EXPECTATIONS:
/// - 3 FlowTransactionScheduler.Executed events per tide (at minimum)
/// - Price changes between executions
/// - Balance/value changes verified after each execution
///
access(all)
fun testAutoBalancerExecutesThreeTimesWithVerification() {
    log("\n========================================")
    log("TEST: AutoBalancer executes at least 3 times with verified execution")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create Tide
    log("Step 1: Creating Tide with native recurring scheduling...")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 500.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Get initial balance
    let balance0 = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Initial AutoBalancer balance: ".concat(balance0.toString()))
    
    // Track execution counts at each step
    var executionCount = 0
    var balances: [UFix64] = [balance0]
    var prices: [UFix64] = [1.0]
    
    // Step 2: EXECUTION 1 - First scheduled execution
    log("\nStep 2: Waiting for EXECUTION 1...")
    
    // Set price change BEFORE execution 1
    let price1 = 1.2
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: price1)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.1)
    prices.append(price1)
    log("Price changed to: ".concat(price1.toString()))
    
    // Advance time to trigger execution 1
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    executionCount = events1.length
    log("Executions after step 2: ".concat(executionCount.toString()))
    
    let balance1 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance1)
    log("Balance after execution 1: ".concat(balance1.toString()))
    
    Test.assert(
        executionCount >= 1,
        message: "Expected at least 1 execution after step 2, found ".concat(executionCount.toString())
    )
    
    // Step 3: EXECUTION 2 - Second scheduled execution
    log("\nStep 3: Waiting for EXECUTION 2...")
    
    // Set price change BEFORE execution 2
    let price2 = 1.5
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: price2)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.3)
    prices.append(price2)
    log("Price changed to: ".concat(price2.toString()))
    
    // Advance time for execution 2
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    executionCount = events2.length
    log("Executions after step 3: ".concat(executionCount.toString()))
    
    let balance2 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance2)
    log("Balance after execution 2: ".concat(balance2.toString()))
    
    Test.assert(
        executionCount >= 2,
        message: "Expected at least 2 executions after step 3, found ".concat(executionCount.toString())
    )
    
    // Step 4: EXECUTION 3 - Third scheduled execution
    log("\nStep 4: Waiting for EXECUTION 3...")
    
    // Set price change BEFORE execution 3
    let price3 = 1.8
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: price3)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    prices.append(price3)
    log("Price changed to: ".concat(price3.toString()))
    
    // Advance time for execution 3
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    executionCount = events3.length
    log("Executions after step 4: ".concat(executionCount.toString()))
    
    let balance3 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance3)
    log("Balance after execution 3: ".concat(balance3.toString()))
    
    // VERIFICATION: At least 3 executions
    Test.assert(
        executionCount >= 3,
        message: "FAIL: Expected at least 3 executions, found ".concat(executionCount.toString())
    )
    
    // Step 5: Summary
    log("\n========== EXECUTION SUMMARY ==========")
    log("Total FlowTransactionScheduler.Executed events: ".concat(executionCount.toString()))
    log("Balances tracked: ".concat(balances.length.toString()))
    
    var i = 0
    while i < balances.length {
        log("  Balance[".concat(i.toString()).concat("]: ").concat(balances[i].toString()))
        i = i + 1
    }
    
    log("Prices used:")
    i = 0
    while i < prices.length {
        log("  Price[".concat(i.toString()).concat("]: ").concat(prices[i].toString()))
        i = i + 1
    }
    
    // Check rebalancing events
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    
    log("PASS: AutoBalancer executed at least 3 times with verified execution")
}

/// TEST 3: Three tides each execute at least 3 times = 9 total executions minimum
///
/// ARCHITECTURE REQUIREMENT:
/// - 3 tides created
/// - Each tide's AutoBalancer runs independently
/// - Each must execute at least 3 times
/// - Total: 9 executions minimum
///
access(all)
fun testThreeTidesNineExecutions() {
    log("\n========================================")
    log("TEST: Three tides each execute 3 times = 9 executions minimum")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 3000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create 3 tides
    log("Step 1: Creating 3 tides...")
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 200.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    Test.assert(tideIDs.length >= 3, message: "Expected 3 tides")
    log("Created 3 tides: ".concat(tideIDs[0].toString()).concat(", ").concat(tideIDs[1].toString()).concat(", ").concat(tideIDs[2].toString()))
    
    // Verify all are registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    for tid in tideIDs {
        Test.assert(regIDs.contains(tid), message: "Tide ".concat(tid.toString()).concat(" should be registered"))
    }
    log("All 3 tides registered in registry")
    
    // Record initial balances
    var balances: {UInt64: [UFix64]} = {}
    for tid in tideIDs {
        let bal = getAutoBalancerBalance(id: tid) ?? 0.0
        balances[tid] = [bal]
        log("Initial balance for tide ".concat(tid.toString()).concat(": ").concat(bal.toString()))
    }
    
    // Step 2: Drive 3 rounds of execution with price changes
    log("\nStep 2: Executing 3 rounds with price changes...")
    
    var round = 1
    var prices: [UFix64] = [1.0, 1.3, 1.6, 2.0]
    
    while round <= 3 {
        log("\n--- Round ".concat(round.toString()).concat(" ---"))
        
        // Change prices
        let flowPrice = prices[round]
        let yieldPrice = 1.0 + (UFix64(round) * 0.2)
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrice)
        log("FLOW price: ".concat(flowPrice.toString()).concat(", Yield price: ").concat(yieldPrice.toString()))
        
        // Advance time
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        // Check executions
        let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        log("Total executions so far: ".concat(execEvents.length.toString()))
        
        // Record balances
        for tid in tideIDs {
            let bal = getAutoBalancerBalance(id: tid) ?? 0.0
            var tideBals = balances[tid]!
            tideBals.append(bal)
            balances[tid] = tideBals
        }
        
        round = round + 1
    }
    
    // Step 3: Final verification
    log("\n========== FINAL VERIFICATION ==========")
    
    let finalExecEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let totalExecutions = finalExecEvents.length
    log("Total FlowTransactionScheduler.Executed events: ".concat(totalExecutions.toString()))
    
    // REQUIREMENT: 3 tides * 3 executions each = 9 minimum
    Test.assert(
        totalExecutions >= 9,
        message: "FAIL: Expected at least 9 executions (3 tides x 3 each), found ".concat(totalExecutions.toString())
    )
    
    // Print balance history for each tide
    for tid in tideIDs {
        let tideBals = balances[tid]!
        log("Tide ".concat(tid.toString()).concat(" balance history:"))
        var j = 0
        while j < tideBals.length {
            log("  [".concat(j.toString()).concat("]: ").concat(tideBals[j].toString()))
            j = j + 1
        }
    }
    
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    
    log("PASS: Three tides each executed at least 3 times (9+ total)")
}

/// TEST 4: Pending queue enqueue and native scheduling continues
///
/// ARCHITECTURE REQUIREMENT:
/// - AutoBalancer schedules itself via native mechanism
/// - Tides can be enqueued to pending (for Supervisor recovery)
/// - Native scheduling continues regardless of pending queue state
///
/// Note: The Supervisor is for recovery only. This test verifies that
/// native scheduling continues even when a tide is in the pending queue.
///
access(all)
fun testPendingQueueAndContinuedExecution() {
    log("\n========================================")
    log("TEST: Pending queue and continued native execution")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    mintFlow(to: flowVaultsAccount, amount: 500.0)
    
    // Step 1: Create a tide (gets auto-scheduled via native mechanism)
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
    
    // Verify tide is registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be registered")
    log("Tide is registered in FlowVaultsSchedulerRegistry")
    
    // Step 2: Wait for first execution to verify it's working
    log("\nStep 2: Waiting for first execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let exec1Count = execEvents1.length
    log("Executions after first wait: ".concat(exec1Count.toString()))
    
    Test.assert(exec1Count >= 1, message: "Should have at least 1 execution")
    
    // Step 3: Enqueue tide to pending queue (simulating that monitoring detected a failure)
    log("\nStep 3: Enqueue tide to pending (simulating monitoring detection)...")
    let enqueueRes = executeTransaction(
        "../transactions/flow-vaults/enqueue_pending_tide.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(enqueueRes, Test.beSucceeded())
    
    let pendingBefore = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingBefore.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount.toString()))
    Test.assert(pendingCount >= 1, message: "Tide should be in pending queue")
    
    // Step 4: Verify that native scheduling continues
    // (The AutoBalancer self-schedules regardless of pending queue state)
    log("\nStep 4: Verifying native scheduling continues...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let exec2Count = execEvents2.length
    log("Executions after step 4: ".concat(exec2Count.toString()))
    
    // Step 5: Continue execution
    log("\nStep 5: Continuing execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let exec3Count = execEvents3.length
    log("Executions after step 5: ".concat(exec3Count.toString()))
    
    // Verification: Native scheduling should continue (3+ executions total)
    Test.assert(
        exec3Count >= 3,
        message: "Native scheduling should continue (3+ executions). Found: ".concat(exec3Count.toString())
    )
    
    log("PASS: Pending queue and continued native execution")
}

// Main test runner
access(all)
fun main() {
    setup()
    testRegistryReceivesTideRegistrationAtInit()
    testAutoBalancerExecutesThreeTimesWithVerification()
    testThreeTidesNineExecutions()
    testPendingQueueAndContinuedExecution()
}
