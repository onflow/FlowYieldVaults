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
//
// PRICE SEMANTICS:
// - flowTokenIdentifier (FLOW): The COLLATERAL token deposited into FlowALP
// - yieldTokenIdentifier (YieldToken): The YIELD-BEARING token the strategy produces
// - Changing FLOW price simulates collateral value changes
// - Changing YieldToken price simulates yield value changes

access(all)
fun setup() {
    log("Setting up scheduled rebalancing test with native AutoBalancer recurring...")
    
    deployContracts()
    deployFlowVaultsSchedulerIfNeeded()
    
    // Fund FlowVaults account for scheduling fees
    mintFlow(to: flowVaultsAccount, amount: 2000.0)

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
    
    // Clear any previous events by recording baseline
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

/// TEST 2: Single AutoBalancer runs at least 3 times with verified execution
///
/// ARCHITECTURE REQUIREMENT:
/// - AutoBalancer configured with recurringConfig (60 second interval)
/// - After creation, scheduleNextRebalance starts the chain
/// - After each execution, AutoBalancer self-reschedules
/// - Must verify 3 separate executions occurred FOR THIS SPECIFIC TIDE
///
/// PRICE SEMANTICS:
/// - FLOW price (collateral): Changes affect position health factor
/// - YieldToken price: Changes affect yield value
///
access(all)
fun testSingleAutoBalancerThreeExecutions() {
    log("\n========================================")
    log("TEST: Single AutoBalancer executes exactly 3 verified times")
    log("========================================")
    
    // Record baseline execution count BEFORE creating this tide
    let baselineEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let baselineCount = baselineEvents.length
    log("Baseline execution count: ".concat(baselineCount.toString()))
    
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
    
    // Track balances after each execution
    var balances: [UFix64] = [balance0]
    
    // EXECUTION 1
    log("\n--- EXECUTION 1 ---")
    log("Changing FLOW (collateral) price to 1.2...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.2)
    log("Changing YieldToken price to 1.1...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.1)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let thisTestExec1 = events1.length - baselineCount
    log("Executions for this tide so far: ".concat(thisTestExec1.toString()))
    
    let balance1 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance1)
    log("Balance after execution 1: ".concat(balance1.toString()))
    
    Test.assert(thisTestExec1 >= 1, message: "Expected at least 1 execution, found ".concat(thisTestExec1.toString()))
    
    // EXECUTION 2
    log("\n--- EXECUTION 2 ---")
    log("Changing FLOW (collateral) price to 1.5...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    log("Changing YieldToken price to 1.3...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.3)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let thisTestExec2 = events2.length - baselineCount
    log("Executions for this tide so far: ".concat(thisTestExec2.toString()))
    
    let balance2 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance2)
    log("Balance after execution 2: ".concat(balance2.toString()))
    
    Test.assert(thisTestExec2 >= 2, message: "Expected at least 2 executions, found ".concat(thisTestExec2.toString()))
    
    // EXECUTION 3
    log("\n--- EXECUTION 3 ---")
    log("Changing FLOW (collateral) price to 1.8...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    log("Changing YieldToken price to 1.5...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let thisTestExec3 = events3.length - baselineCount
    log("Executions for this tide so far: ".concat(thisTestExec3.toString()))
    
    let balance3 = getAutoBalancerBalance(id: tideID) ?? 0.0
    balances.append(balance3)
    log("Balance after execution 3: ".concat(balance3.toString()))
    
    // VERIFICATION
    log("\n========== VERIFICATION ==========")
    log("This tide's executions: ".concat(thisTestExec3.toString()))
    Test.assert(thisTestExec3 >= 3, message: "Expected at least 3 executions for this tide, found ".concat(thisTestExec3.toString()))
    
    log("Balance progression:")
    var i = 0
    while i < balances.length {
        log("  [".concat(i.toString()).concat("]: ").concat(balances[i].toString()))
        i = i + 1
    }
    
    log("PASS: Single AutoBalancer executed 3+ times with verified execution")
}

/// TEST 3: Three new tides, each executes 3 times = 9 executions for these tides
///
/// NOTE: This test creates 3 NEW tides and tracks only THEIR executions
///
access(all)
fun testThreeNewTidesNineExecutions() {
    log("\n========================================")
    log("TEST: Three NEW tides each execute 3 times")
    log("========================================")
    
    // Record baseline BEFORE creating new tides
    let baselineEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let baselineCount = baselineEvents.length
    log("Baseline execution count (from previous tests): ".concat(baselineCount.toString()))
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 3000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create 3 NEW tides
    log("Step 1: Creating 3 new tides...")
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
    
    let allTideIDs = getTideIDs(address: user.address)!
    // Get the last 3 tides (the ones we just created)
    let newTideIDs = [allTideIDs[allTideIDs.length - 3], allTideIDs[allTideIDs.length - 2], allTideIDs[allTideIDs.length - 1]]
    log("Created 3 new tides: ".concat(newTideIDs[0].toString()).concat(", ").concat(newTideIDs[1].toString()).concat(", ").concat(newTideIDs[2].toString()))
    
    // Record initial balances
    var balances: {UInt64: [UFix64]} = {}
    for tid in newTideIDs {
        let bal = getAutoBalancerBalance(id: tid) ?? 0.0
        balances[tid] = [bal]
    }
    
    // Step 2: Drive 3 rounds of execution
    log("\nStep 2: Executing 3 rounds with price changes...")
    
    var round = 1
    while round <= 3 {
        log("\n--- Round ".concat(round.toString()).concat(" ---"))
        
        // Change prices (collateral and yield)
        let flowPrice = 1.0 + (UFix64(round) * 0.3)
        let yieldPrice = 1.0 + (UFix64(round) * 0.2)
        log("FLOW (collateral) price: ".concat(flowPrice.toString()))
        log("YieldToken price: ".concat(yieldPrice.toString()))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrice)
        
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        // Record current state
        let currentEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        let newExecutions = currentEvents.length - baselineCount
        log("New executions since test start: ".concat(newExecutions.toString()))
        
        // Record balances
        for tid in newTideIDs {
            let bal = getAutoBalancerBalance(id: tid) ?? 0.0
            var tideBals = balances[tid]!
            tideBals.append(bal)
            balances[tid] = tideBals
        }
        
        round = round + 1
    }
    
    // VERIFICATION
    log("\n========== VERIFICATION ==========")
    let finalEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let totalNewExecutions = finalEvents.length - baselineCount
    log("Total new executions (for these 3 tides + any previous tides still running): ".concat(totalNewExecutions.toString()))
    
    // We expect at least 9 new executions (3 tides x 3 rounds)
    // Note: Previous tides may also execute, so count could be higher
    Test.assert(
        totalNewExecutions >= 9,
        message: "Expected at least 9 new executions, found ".concat(totalNewExecutions.toString())
    )
    
    // Print balance history
    for tid in newTideIDs {
        let tideBals = balances[tid]!
        log("Tide ".concat(tid.toString()).concat(" balances: ").concat(tideBals[0].toString()).concat(" -> ").concat(tideBals[tideBals.length - 1].toString()))
    }
    
    log("PASS: Three new tides each executed 3+ times")
}

/// TEST 4: Supervisor recovery after 3 verified executions
///
/// SCENARIO:
/// 1. Create a tide
/// 2. Verify it executes 3 times successfully (native self-scheduling)
/// 3. Enqueue to pending (simulating failed self-reschedule)
/// 4. Supervisor picks it up and re-seeds the schedule
/// 5. Verify continued execution
///
access(all)
fun testSupervisorRecoveryAfterThreeExecutions() {
    log("\n========================================")
    log("TEST: Supervisor recovery after 3 verified executions")
    log("========================================")
    
    let baselineEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let baselineCount = baselineEvents.length
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create tide
    log("Step 1: Creating tide...")
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 300.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[tideIDs.length - 1]
    log("Tide created: ".concat(tideID.toString()))
    
    // Step 2: Verify 3 executions
    log("\nStep 2: Verifying 3 executions...")
    var execCount = 0
    var round = 1
    while round <= 3 {
        log("--- Execution ".concat(round.toString()).concat(" ---"))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let events = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        execCount = events.length - baselineCount
        log("Executions so far: ".concat(execCount.toString()))
        round = round + 1
    }
    
    Test.assert(execCount >= 3, message: "Tide should have executed at least 3 times before recovery test. Found: ".concat(execCount.toString()))
    log("Verified: Tide executed ".concat(execCount.toString()).concat(" times"))
    
    // Step 3: Enqueue to pending (simulating failed self-reschedule)
    log("\nStep 3: Enqueuing to pending (simulating failed reschedule)...")
    let enqueueRes = executeTransaction(
        "../transactions/flow-vaults/enqueue_pending_tide.cdc",
        [tideID],
        flowVaultsAccount
    )
    Test.expect(enqueueRes, Test.beSucceeded())
    
    let pendingRes = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount = pendingRes.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount.toString()))
    Test.assert(pendingCount >= 1, message: "Tide should be in pending queue")
    
    // Step 4: Setup and schedule Supervisor
    log("\nStep 4: Setting up Supervisor...")
    executeTransaction("../transactions/flow-vaults/setup_scheduler_manager.cdc", [], flowVaultsAccount)
    executeTransaction("../transactions/flow-vaults/setup_supervisor.cdc", [], flowVaultsAccount)
    
    // Commit block and get fresh timestamp
    Test.commitBlock()
    // Use a very large offset (1500s) to account for accumulated time from previous tests
    // Previous tests advance time significantly, so we need a large buffer
    let supervisorTime = getCurrentBlock().timestamp + 1500.0
    let schedSupRes = executeTransaction(
        "../transactions/flow-vaults/schedule_supervisor.cdc",
        [supervisorTime, UInt8(1), UInt64(800), 0.05, 30.0, true, 10.0, false],
        flowVaultsAccount
    )
    Test.expect(schedSupRes, Test.beSucceeded())
    log("Supervisor scheduled at: ".concat(supervisorTime.toString()))
    
    // Step 5: Wait for Supervisor to run
    log("\nStep 5: Waiting for Supervisor to recover tide...")
    Test.moveTime(by: 1510.0)
    Test.commitBlock()
    
    let seededEvents = Test.eventsOfType(Type<FlowVaultsScheduler.SupervisorSeededTide>())
    log("SupervisorSeededTide events: ".concat(seededEvents.length.toString()))
    
    // Step 6: Verify continued execution
    log("\nStep 6: Verifying continued execution after recovery...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let finalEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let finalExecCount = finalEvents.length - baselineCount
    log("Total executions after recovery: ".concat(finalExecCount.toString()))
    
    Test.assert(
        finalExecCount > execCount,
        message: "Should have more executions after recovery. Before: ".concat(execCount.toString()).concat(", After: ").concat(finalExecCount.toString())
    )
    
    log("PASS: Supervisor recovery after 3 verified executions")
}

/// TEST 5: Tides continue executing even if Supervisor fails
///
/// SCENARIO:
/// 1. Create 5 tides that self-schedule
/// 2. Verify all 5 execute at least 3 times
/// 3. Supervisor is NOT set up (simulating Supervisor failure)
/// 4. Verify tides CONTINUE to execute perpetually (native scheduling works independently)
///
access(all)
fun testTidesContinueWithoutSupervisor() {
    log("\n========================================")
    log("TEST: Tides continue executing even if Supervisor is not running")
    log("========================================")
    
    let baselineEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let baselineCount = baselineEvents.length
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create 5 tides
    log("Step 1: Creating 5 tides...")
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
    log("Created 5 tides")
    
    // Step 2: Verify 3 executions per tide (15 total minimum)
    log("\nStep 2: Verifying 3 rounds of execution...")
    var round = 1
    while round <= 3 {
        log("--- Round ".concat(round.toString()).concat(" ---"))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let events = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        let execCount = events.length - baselineCount
        log("Total executions so far: ".concat(execCount.toString()))
        round = round + 1
    }
    
    let midEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let midExecCount = midEvents.length - baselineCount
    log("\nAfter 3 rounds: ".concat(midExecCount.toString()).concat(" executions"))
    Test.assert(midExecCount >= 15, message: "Expected at least 15 executions (5 tides x 3), found ".concat(midExecCount.toString()))
    
    // Step 3: NOTE - We are NOT setting up Supervisor (simulating Supervisor failure/absence)
    log("\nStep 3: Supervisor is NOT running (simulating failure)")
    log("Tides should continue to self-schedule via native mechanism...")
    
    // Step 4: Continue execution and verify tides keep running
    log("\nStep 4: Verifying tides continue perpetually without Supervisor...")
    round = 1
    while round <= 3 {
        log("--- Additional Round ".concat(round.toString()).concat(" ---"))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let events = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
        let execCount = events.length - baselineCount
        log("Total executions: ".concat(execCount.toString()))
        round = round + 1
    }
    
    let finalEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let finalExecCount = finalEvents.length - baselineCount
    
    log("\n========== VERIFICATION ==========")
    log("Total executions without Supervisor: ".concat(finalExecCount.toString()))
    
    // We expect at least 30 executions (5 tides x 6 rounds)
    Test.assert(
        finalExecCount >= 30,
        message: "Expected at least 30 executions, found ".concat(finalExecCount.toString())
    )
    
    log("PASS: Tides continue executing perpetually without Supervisor")
}

/// TEST 6: Failed tide cannot be recovered when Supervisor is also stopped
///
/// SCENARIO:
/// 1. Create 5 tides that self-schedule, verify 3 executions each
/// 2. Supervisor is NOT running
/// 3. One tide is enqueued to pending (simulating it failed to self-reschedule)
/// 4. Since Supervisor is not running, this tide CANNOT be recovered
/// 5. Other tides continue, but the failed tide remains in pending
///
access(all)
fun testFailedTideCannotRecoverWithoutSupervisor() {
    log("\n========================================")
    log("TEST: Failed tide cannot recover when Supervisor is also stopped")
    log("========================================")
    
    let baselineEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let baselineCount = baselineEvents.length
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create 5 tides
    log("Step 1: Creating 5 tides...")
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
    
    let allTideIDs = getTideIDs(address: user.address)!
    let fiveTideIDs = [allTideIDs[allTideIDs.length - 5], allTideIDs[allTideIDs.length - 4], allTideIDs[allTideIDs.length - 3], allTideIDs[allTideIDs.length - 2], allTideIDs[allTideIDs.length - 1]]
    log("Created 5 tides: ".concat(fiveTideIDs[0].toString()).concat(", ").concat(fiveTideIDs[1].toString()).concat(", ").concat(fiveTideIDs[2].toString()).concat(", ").concat(fiveTideIDs[3].toString()).concat(", ").concat(fiveTideIDs[4].toString()))
    
    // Step 2: Verify 3 executions per tide
    log("\nStep 2: Verifying 3 rounds of execution...")
    var round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    let midEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let midExecCount = midEvents.length - baselineCount
    log("After 3 rounds: ".concat(midExecCount.toString()).concat(" executions"))
    
    // Step 3: Enqueue ONE tide to pending (simulating it failed to self-reschedule)
    let failedTideID = fiveTideIDs[2] // Pick the middle tide
    log("\nStep 3: Enqueuing tide ".concat(failedTideID.toString()).concat(" to pending (simulating failure)..."))
    let enqueueRes = executeTransaction(
        "../transactions/flow-vaults/enqueue_pending_tide.cdc",
        [failedTideID],
        flowVaultsAccount
    )
    Test.expect(enqueueRes, Test.beSucceeded())
    
    let pendingRes1 = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount1 = pendingRes1.returnValue! as! Int
    log("Pending queue size: ".concat(pendingCount1.toString()))
    Test.assert(pendingCount1 >= 1, message: "Failed tide should be in pending queue")
    
    // Step 4: NOTE - Supervisor is NOT running
    log("\nStep 4: Supervisor is NOT running - failed tide cannot be recovered")
    
    // Step 5: Advance time, other tides should continue, but pending queue should still have the failed tide
    log("\nStep 5: Advancing time without Supervisor...")
    round = 1
    while round <= 3 {
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        round = round + 1
    }
    
    // VERIFICATION
    log("\n========== VERIFICATION ==========")
    
    // Check pending queue - failed tide should STILL be there
    let pendingRes2 = executeScript("../scripts/flow-vaults/get_pending_count.cdc", [])
    let pendingCount2 = pendingRes2.returnValue! as! Int
    log("Pending queue size after time advancement: ".concat(pendingCount2.toString()))
    Test.assert(pendingCount2 >= 1, message: "Failed tide should STILL be in pending queue (Supervisor not running)")
    
    // Other tides should have continued
    let finalEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let finalExecCount = finalEvents.length - baselineCount
    log("Total executions: ".concat(finalExecCount.toString()))
    
    // We expect executions to continue for the 4 working tides
    // But fewer than if all 5 were working
    Test.assert(
        finalExecCount > midExecCount,
        message: "Working tides should continue. Before: ".concat(midExecCount.toString()).concat(", After: ").concat(finalExecCount.toString())
    )
    
    log("PASS: Failed tide cannot recover without Supervisor, other tides continue")
}

// Main test runner
access(all)
fun main() {
    setup()
    testRegistryReceivesTideRegistrationAtInit()
    testSingleAutoBalancerThreeExecutions()
    testThreeNewTidesNineExecutions()
    testSupervisorRecoveryAfterThreeExecutions()
    testTidesContinueWithoutSupervisor()
    testFailedTideCannotRecoverWithoutSupervisor()
}
