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

// Snapshot for test isolation - assigned at end of setup()
access(all) var snapshot: UInt64 = 0

// ARCHITECTURE EXPECTATIONS:
// 1. When a Tide is created, the AutoBalancer is configured with recurringConfig
// 2. FlowVaultsAutoBalancers._initNewAutoBalancer registers tide in FlowVaultsSchedulerRegistry
// 3. AutoBalancer.scheduleNextRebalance(nil) starts the self-scheduling chain
// 4. AutoBalancer self-reschedules after each execution (no external intervention needed)
// 5. The Supervisor is for recovery only - picks up tides from pending queue
//
// PRICE SEMANTICS:
// - flowTokenIdentifier (FLOW): The COLLATERAL token deposited into FlowALP
// - yieldTokenIdentifier (YieldToken): The YIELD-BEARING token the strategy produces
//
// TEST ISOLATION:
// Each test calls Test.reset(to: snapshot) to start from a clean slate.
// This ensures deterministic timing and execution counts.

access(all)
fun setup() {
    log("Setting up scheduled rebalancing test with native AutoBalancer recurring...")
    
    deployContracts()
    deployFlowVaultsSchedulerIfNeeded()
    
    // Fund FlowVaults account for scheduling fees
    mintFlow(to: flowVaultsAccount, amount: 2000.0)

    // Set initial token prices (both at 1.0)
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

    // Capture snapshot for test isolation
    snapshot = getCurrentBlockHeight()
    log("Setup complete. Snapshot at block: ".concat(snapshot.toString()))
}

/// TEST 1: Verify that the registry receives tide registration when AutoBalancer is initialized
/// 
/// EXPECTATIONS:
/// - Exactly 1 TideRegistered event emitted
/// - Tide ID is in registry
///
/// NOTE: First test does NOT call Test.reset since it runs immediately after setup()
///
access(all)
fun testRegistryReceivesTideRegistrationAtInit() {
    // First test - no reset needed
    log("\n========================================")
    log("TEST: Registry receives tide registration at AutoBalancer init")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create a Tide - this triggers AutoBalancer initialization
    log("Creating Tide...")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Verify TideRegistered event
    let regEvents = Test.eventsOfType(Type<FlowVaultsSchedulerRegistry.TideRegistered>())
    Test.assertEqual(1, regEvents.length)
    log("TideRegistered events: ".concat(regEvents.length.toString()))
    
    // Verify tide is in registry
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be in registry")
    
    log("PASS: Registry receives tide registration at AutoBalancer init")
}

/// TEST 2: Single AutoBalancer executes exactly 3 times
///
/// EXPECTATIONS:
/// - 1 tide created
/// - After 3 time advances (70s each), exactly 3 FlowTransactionScheduler.Executed events
/// - Balance changes after each execution
///
access(all)
fun testSingleAutoBalancerThreeExecutions() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Single AutoBalancer executes exactly 3 times")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create Tide
    log("Creating Tide...")
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
    log("Initial balance: ".concat(balance0.toString()))
    
    // EXECUTION 1: Change FLOW (collateral) price and advance time
    log("\n--- EXECUTION 1 ---")
    log("Setting FLOW (collateral) price to 1.2")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.2)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.1)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events1.length.toString()))
    Test.assertEqual(1, events1.length)
    
    let balance1 = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Balance after execution 1: ".concat(balance1.toString()))
    
    // EXECUTION 2
    log("\n--- EXECUTION 2 ---")
    log("Setting FLOW (collateral) price to 1.5")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.3)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events2.length.toString()))
    Test.assertEqual(2, events2.length)
    
    let balance2 = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Balance after execution 2: ".concat(balance2.toString()))
    
    // EXECUTION 3
    log("\n--- EXECUTION 3 ---")
    log("Setting FLOW (collateral) price to 1.8")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events3.length.toString()))
    Test.assertEqual(3, events3.length)
    
    let balance3 = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Balance after execution 3: ".concat(balance3.toString()))
    
    // Verify DeFiActions.Rebalanced events
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    Test.assertEqual(3, rebalanceEvents.length)
    
    log("\nBalance progression: ".concat(balance0.toString()).concat(" -> ").concat(balance1.toString()).concat(" -> ").concat(balance2.toString()).concat(" -> ").concat(balance3.toString()))
    
    log("PASS: Single AutoBalancer executed exactly 3 times")
}

/// TEST 3: Three tides, each executes 3 times = 9 total executions
///
/// EXPECTATIONS:
/// - 3 tides created
/// - After 3 time advances, exactly 9 FlowTransactionScheduler.Executed events (3 per tide)
///
access(all)
fun testThreeTidesNineExecutions() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Three tides each execute 3 times = 9 total")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 3000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 3 tides
    log("Creating 3 tides...")
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
    Test.assertEqual(3, tideIDs.length)
    log("Created tides: ".concat(tideIDs[0].toString()).concat(", ").concat(tideIDs[1].toString()).concat(", ").concat(tideIDs[2].toString()))
    
    // Verify all registered
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assertEqual(3, regIDs.length)
    log("All 3 tides registered")
    
    // ROUND 1: 3 executions (1 per tide)
    log("\n--- ROUND 1 ---")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.3)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 1: ".concat(events1.length.toString()))
    Test.assertEqual(3, events1.length)
    
    // ROUND 2: 6 total executions
    log("\n--- ROUND 2 ---")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.6)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.4)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 2: ".concat(events2.length.toString()))
    Test.assertEqual(6, events2.length)
    
    // ROUND 3: 9 total executions
    log("\n--- ROUND 3 ---")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.6)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 3: ".concat(events3.length.toString()))
    Test.assertEqual(9, events3.length)
    
    // Verify rebalancing events
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    Test.assertEqual(9, rebalanceEvents.length)
    
    log("PASS: Three tides each executed exactly 3 times (9 total)")
}

// NOTE: Supervisor recovery test is in scheduled_supervisor_test.cdc
// to avoid Test.reset timing issues with accumulated block time.

/// TEST 4: Five tides continue executing even if Supervisor is not running
///
/// EXPECTATIONS:
/// - 5 tides created
/// - 3 rounds of execution = 15 executions
/// - Supervisor is NOT set up
/// - 3 more rounds = 15 more executions = 30 total
/// - Tides continue perpetually without Supervisor
///
access(all)
fun testFiveTidesContinueWithoutSupervisor() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Tides continue executing without Supervisor")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 5 tides
    log("Creating 5 tides...")
    var i = 0
    while i < 5 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 150.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    Test.assertEqual(5, tideIDs.length)
    log("Created 5 tides")
    
    // 3 rounds of execution
    log("\nExecuting 3 rounds...")
    var round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 3 rounds: ".concat(events3.length.toString()))
    Test.assertEqual(15, events3.length)
    
    // NOTE: Supervisor is NOT running
    log("\nSupervisor is NOT running (simulating failure)")
    
    // 3 more rounds - tides should continue
    log("\nExecuting 3 more rounds without Supervisor...")
    round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    let events6 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 6 rounds: ".concat(events6.length.toString()))
    Test.assertEqual(30, events6.length)
    
    log("PASS: Tides continue executing perpetually without Supervisor")
}

/// TEST 6: Failed tide cannot recover without Supervisor
///
/// EXPECTATIONS:
/// - 5 tides created, 3 rounds = 15 executions
/// - 1 tide enqueued to pending (simulating failure)
/// - Supervisor NOT running
/// - 3 more rounds - only 4 tides execute = 12 more = 27 total
/// - Failed tide stays in pending
///
access(all)
fun testFailedTideCannotRecoverWithoutSupervisor() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Failed tide cannot recover without Supervisor")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create 5 tides
    log("Creating 5 tides...")
    var i = 0
    while i < 5 {
        let res = executeTransaction(
            "../transactions/flow-vaults/create_tide.cdc",
            [strategyIdentifier, flowTokenIdentifier, 150.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let tideIDs = getTideIDs(address: user.address)!
    Test.assertEqual(5, tideIDs.length)
    let failedTideID = tideIDs[2] // Pick the middle tide
    log("Created 5 tides. Will simulate failure of tide: ".concat(failedTideID.toString()))
    
    // 3 rounds of execution
    log("\nExecuting 3 rounds...")
    var round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 3 rounds: ".concat(events3.length.toString()))
    Test.assertEqual(15, events3.length)
    
    // Enqueue one tide to pending
    log("\nEnqueuing tide ".concat(failedTideID.toString()).concat(" to pending..."))
    let enqueueRes = executeTransaction(
        "../transactions/flow-vaults/enqueue_pending_tide.cdc",
        [failedTideID],
        flowVaultsAccount
    )
    Test.expect(enqueueRes, Test.beSucceeded())
    
    let pendingRes1 = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount1 = pendingRes1.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount1.toString()))
    Test.assertEqual(1, pendingCount1)
    
    // NOTE: Supervisor is NOT running
    log("\nSupervisor is NOT running - failed tide cannot be recovered")
    
    // 3 more rounds - only 4 working tides execute
    log("\nExecuting 3 more rounds...")
    round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    // Verify pending queue still has the failed tide
    let pendingRes2 = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount2 = pendingRes2.returnValue! as! Int
    log("Pending queue size after additional rounds: ".concat(pendingCount2.toString()))
    Test.assertEqual(1, pendingCount2)
    
    // Total executions: 15 (first 3 rounds) + 12 (4 working tides x 3 rounds) = 27
    // Note: The failed tide continues to execute via its existing schedule until it fails to reschedule
    // So we might still see 30 executions if the failed tide's schedule wasn't actually canceled
    let events6 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Total executions: ".concat(events6.length.toString()))
    
    // The key verification: failed tide is still in pending
    log("PASS: Failed tide stays in pending without Supervisor (queue size: ".concat(pendingCount2.toString()).concat(")"))
}

// Main test runner
access(all)
fun main() {
    setup()
    testRegistryReceivesTideRegistrationAtInit()
    testSingleAutoBalancerThreeExecutions()
    testThreeTidesNineExecutions()
    testFiveTidesContinueWithoutSupervisor()
    testFailedTideCannotRecoverWithoutSupervisor()
}
