import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "FlowYieldVaultsSchedulerRegistry"
import "DeFiActions"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

// Snapshot for test isolation - assigned at end of setup()
access(all) var snapshot: UInt64 = 0

// ARCHITECTURE EXPECTATIONS:
// 1. When a YieldVault is created, the AutoBalancer is configured with recurringConfig
// 2. FlowYieldVaultsAutoBalancers._initNewAutoBalancer registers yield vault in FlowYieldVaultsSchedulerRegistry
// 3. AutoBalancer.scheduleNextRebalance(nil) starts the self-scheduling chain
// 4. AutoBalancer self-reschedules after each execution (no external intervention needed)
// 5. The Supervisor is for recovery only - picks up yield vaults from pending queue
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
    
    // Fund FlowYieldVaults account for scheduling fees
    mintFlow(to: flowYieldVaultsAccount, amount: 2000.0)

    // Set initial token prices (both at 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

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
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        yearlyRate: UFix128(0.1),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Enable Strategy creation
    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )

    // Capture snapshot for test isolation
    snapshot = getCurrentBlockHeight()
    log("Setup complete. Snapshot at block: ".concat(snapshot.toString()))
}

/// TEST 1: Verify that the registry receives yield vault registration when AutoBalancer is initialized
/// 
/// EXPECTATIONS:
/// - Exactly 1 YieldVaultRegistered event emitted
/// - YieldVault ID is in registry
///
/// NOTE: First test does NOT call Test.reset since it runs immediately after setup()
///
access(all)
fun testRegistryReceivesYieldVaultRegistrationAtInit() {
    // First test - no reset needed
    log("\n========================================")
    log("TEST: Registry receives yield vault registration at AutoBalancer init")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 1000.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create a YieldVault - this triggers AutoBalancer initialization
    log("Creating YieldVault...")
    let createYieldVaultRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createYieldVaultRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created with ID: ".concat(yieldVaultID.toString()))
    
    // Verify YieldVaultRegistered event
    let regEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerRegistry.YieldVaultRegistered>())
    Test.assertEqual(1, regEvents.length)
    log("YieldVaultRegistered events: ".concat(regEvents.length.toString()))
    
    // Verify yield vault is in registry
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(yieldVaultID), message: "YieldVault should be in registry")
    
    log("PASS: Registry receives yield vault registration at AutoBalancer init")
}

/// TEST 2: Single AutoBalancer executes exactly 3 times
///
/// EXPECTATIONS:
/// - 1 yield vault created
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
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create YieldVault
    log("Creating YieldVault...")
    let createYieldVaultRes = executeTransaction(
        "../transactions/flow-yield-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 500.0],
        user
    )
    Test.expect(createYieldVaultRes, Test.beSucceeded())
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    let yieldVaultID = yieldVaultIDs[0]
    log("YieldVault created with ID: ".concat(yieldVaultID.toString()))
    
    // Get initial balance
    let balance0 = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
    log("Initial balance: ".concat(balance0.toString()))
    
    // EXECUTION 1: Change FLOW (collateral) price and advance time
    log("\n--- EXECUTION 1 ---")
    log("Setting FLOW (collateral) price to 1.2")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.2)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.1)
    
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events1.length.toString()))
    Test.assertEqual(1, events1.length)
    
    let balance1 = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
    log("Balance after execution 1: ".concat(balance1.toString()))
    Test.assert(balance1 != balance0, message: "Balance should change after execution 1 (was: ".concat(balance0.toString()).concat(", now: ").concat(balance1.toString()).concat(")"))
    
    // EXECUTION 2
    log("\n--- EXECUTION 2 ---")
    log("Setting FLOW (collateral) price to 1.5")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.3)
    
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events2.length.toString()))
    Test.assertEqual(2, events2.length)
    
    let balance2 = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
    log("Balance after execution 2: ".concat(balance2.toString()))
    Test.assert(balance2 != balance1, message: "Balance should change after execution 2 (was: ".concat(balance1.toString()).concat(", now: ").concat(balance2.toString()).concat(")"))
    
    // EXECUTION 3
    log("\n--- EXECUTION 3 ---")
    log("Setting FLOW (collateral) price to 1.8")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.8)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Scheduler.Executed events: ".concat(events3.length.toString()))
    Test.assertEqual(3, events3.length)
    
    let balance3 = getAutoBalancerBalance(id: yieldVaultID) ?? 0.0
    log("Balance after execution 3: ".concat(balance3.toString()))
    Test.assert(balance3 != balance2, message: "Balance should change after execution 3 (was: ".concat(balance2.toString()).concat(", now: ").concat(balance3.toString()).concat(")"))
    
    // Verify DeFiActions.Rebalanced events
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    Test.assertEqual(3, rebalanceEvents.length)
    
    log("\nBalance progression: ".concat(balance0.toString()).concat(" -> ").concat(balance1.toString()).concat(" -> ").concat(balance2.toString()).concat(" -> ").concat(balance3.toString()))
    
    log("PASS: Single AutoBalancer executed exactly 3 times")
}

/// TEST 3: Three yield vaults, each executes 3 times = 9 total executions
///
/// EXPECTATIONS:
/// - 3 yield vaults created
/// - After 3 time advances, exactly 9 FlowTransactionScheduler.Executed events (3 per yield vault)
///
access(all)
fun testThreeYieldVaultsNineExecutions() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Three yield vaults each execute 3 times = 9 total")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 3000.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create 3 yield vaults
    log("Creating 3 yield vaults...")
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 200.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    Test.assertEqual(3, yieldVaultIDs.length)
    log("Created yield vaults: ".concat(yieldVaultIDs[0].toString()).concat(", ").concat(yieldVaultIDs[1].toString()).concat(", ").concat(yieldVaultIDs[2].toString()))
    
    // Verify all registered
    let regIDsRes = executeScript("../scripts/flow-yield-vaults/get_registered_yield_vault_ids.cdc", [])
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assertEqual(3, regIDs.length)
    log("All 3 yield vaults registered")
    
    // Track initial balances for all 3 yield vaults
    var balance0_prev = getAutoBalancerBalance(id: yieldVaultIDs[0]) ?? 0.0
    var balance1_prev = getAutoBalancerBalance(id: yieldVaultIDs[1]) ?? 0.0
    var balance2_prev = getAutoBalancerBalance(id: yieldVaultIDs[2]) ?? 0.0
    log("Initial balances: T0=".concat(balance0_prev.toString()).concat(", T1=").concat(balance1_prev.toString()).concat(", T2=").concat(balance2_prev.toString()))
    
    // ROUND 1: 3 executions (1 per yield vault)
    log("\n--- ROUND 1 ---")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.3)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2)
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 1: ".concat(events1.length.toString()))
    Test.assertEqual(3, events1.length)
    
    // Verify balance changes for round 1
    var balance0_r1 = getAutoBalancerBalance(id: yieldVaultIDs[0]) ?? 0.0
    var balance1_r1 = getAutoBalancerBalance(id: yieldVaultIDs[1]) ?? 0.0
    var balance2_r1 = getAutoBalancerBalance(id: yieldVaultIDs[2]) ?? 0.0
    log("Round 1 balances: T0=".concat(balance0_r1.toString()).concat(", T1=").concat(balance1_r1.toString()).concat(", T2=").concat(balance2_r1.toString()))
    Test.assert(balance0_r1 != balance0_prev, message: "YieldVault 0 balance should change after round 1")
    Test.assert(balance1_r1 != balance1_prev, message: "YieldVault 1 balance should change after round 1")
    Test.assert(balance2_r1 != balance2_prev, message: "YieldVault 2 balance should change after round 1")
    
    // ROUND 2: 6 total executions
    log("\n--- ROUND 2 ---")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.6)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.4)
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 2: ".concat(events2.length.toString()))
    Test.assertEqual(6, events2.length)
    
    // Verify balance changes for round 2
    var balance0_r2 = getAutoBalancerBalance(id: yieldVaultIDs[0]) ?? 0.0
    var balance1_r2 = getAutoBalancerBalance(id: yieldVaultIDs[1]) ?? 0.0
    var balance2_r2 = getAutoBalancerBalance(id: yieldVaultIDs[2]) ?? 0.0
    log("Round 2 balances: T0=".concat(balance0_r2.toString()).concat(", T1=").concat(balance1_r2.toString()).concat(", T2=").concat(balance2_r2.toString()))
    Test.assert(balance0_r2 != balance0_r1, message: "YieldVault 0 balance should change after round 2")
    Test.assert(balance1_r2 != balance1_r1, message: "YieldVault 1 balance should change after round 2")
    Test.assert(balance2_r2 != balance2_r1, message: "YieldVault 2 balance should change after round 2")
    
    // ROUND 3: 9 total executions
    log("\n--- ROUND 3 ---")
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.6)
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after round 3: ".concat(events3.length.toString()))
    Test.assertEqual(9, events3.length)
    
    // Verify balance changes for round 3
    var balance0_r3 = getAutoBalancerBalance(id: yieldVaultIDs[0]) ?? 0.0
    var balance1_r3 = getAutoBalancerBalance(id: yieldVaultIDs[1]) ?? 0.0
    var balance2_r3 = getAutoBalancerBalance(id: yieldVaultIDs[2]) ?? 0.0
    log("Round 3 balances: T0=".concat(balance0_r3.toString()).concat(", T1=").concat(balance1_r3.toString()).concat(", T2=").concat(balance2_r3.toString()))
    Test.assert(balance0_r3 != balance0_r2, message: "YieldVault 0 balance should change after round 3")
    Test.assert(balance1_r3 != balance1_r2, message: "YieldVault 1 balance should change after round 3")
    Test.assert(balance2_r3 != balance2_r2, message: "YieldVault 2 balance should change after round 3")
    
    // Verify rebalancing events
    let rebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    log("DeFiActions.Rebalanced events: ".concat(rebalanceEvents.length.toString()))
    Test.assertEqual(9, rebalanceEvents.length)
    
    log("PASS: Three yield vaults each executed exactly 3 times (9 total)")
}

// NOTE: Supervisor recovery test is in scheduled_supervisor_test.cdc
// to avoid Test.reset timing issues with accumulated block time.

/// TEST 4: Five yield vaults continue executing even if Supervisor is not running
///
/// EXPECTATIONS:
/// - 5 yield vaults created
/// - 3 rounds of execution = 15 executions
/// - Supervisor is NOT set up
/// - 3 more rounds = 15 more executions = 30 total
/// - YieldVaults continue perpetually without Supervisor
///
access(all)
fun testFiveYieldVaultsContinueWithoutSupervisor() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: YieldVaults continue executing without Supervisor")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 5000.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Create 5 yield vaults
    log("Creating 5 yield vaults...")
    var i = 0
    while i < 5 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 150.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    Test.assertEqual(5, yieldVaultIDs.length)
    log("Created 5 yield vaults")
    
    // Track balances for all 5 yield vaults - use arrays for tracking
    var prevBalances: [UFix64] = []
    var idx = 0
    while idx < 5 {
        prevBalances.append(getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0)
        idx = idx + 1
    }
    log("Initial balances: T0=".concat(prevBalances[0].toString()).concat(", T1=").concat(prevBalances[1].toString()).concat(", T2=").concat(prevBalances[2].toString()).concat(", T3=").concat(prevBalances[3].toString()).concat(", T4=").concat(prevBalances[4].toString()))
    
    // 3 rounds of execution with balance verification
    log("\nExecuting 3 rounds...")
    var round = 1
    while round <= 3 {
        // Use significant price changes to ensure rebalancing triggers
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.3))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        
        // Verify all 5 yield vaults changed balance
        idx = 0
        while idx < 5 {
            let newBal = getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0
            Test.assert(newBal != prevBalances[idx], message: "YieldVault ".concat(idx.toString()).concat(" balance should change after round ").concat(round.toString()))
            prevBalances[idx] = newBal
            idx = idx + 1
        }
        log("Round ".concat(round.toString()).concat(" balances verified for all 5 yield vaults"))
        round = round + 1
    }
    
    let events3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 3 rounds: ".concat(events3.length.toString()))
    Test.assertEqual(15, events3.length)
    
    // NOTE: Supervisor is NOT running
    log("\nSupervisor is NOT running (simulating failure)")
    
    // 3 more rounds - yield vaults should continue with balance verification
    log("\nExecuting 3 more rounds without Supervisor...")
    round = 1
    while round <= 3 {
        // Use significantly different prices for second set of rounds
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0 + (UFix64(round) * 0.3))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5 + (UFix64(round) * 0.2))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        
        // Verify all 5 yield vaults changed balance
        idx = 0
        while idx < 5 {
            let newBal = getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0
            Test.assert(newBal != prevBalances[idx], message: "YieldVault ".concat(idx.toString()).concat(" balance should change after round ").concat((round + 3).toString()))
            prevBalances[idx] = newBal
            idx = idx + 1
        }
        log("Round ".concat((round + 3).toString()).concat(" balances verified for all 5 yield vaults"))
        round = round + 1
    }
    
    let events6 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 6 rounds: ".concat(events6.length.toString()))
    Test.assertEqual(30, events6.length)
    
    log("PASS: YieldVaults continue executing perpetually without Supervisor with verified balance changes")
}

/// TEST 6: Healthy yield vaults never become stuck
///
/// This test verifies that healthy yield vaults (with sufficient funding) continue to execute
/// without ever needing Supervisor intervention. The Supervisor is a RECOVERY mechanism
/// for yield vaults that fail to self-reschedule.
///
/// Tests that a yield vault that fails to reschedule cannot recover without Supervisor
/// 
/// TEST SCENARIO:
/// 1. Create 3 yield vaults, let them execute 2 rounds (healthy)
/// 2. Drain FLOW from the fee vault (causes reschedule failures)
/// 3. Wait for yield vaults to fail rescheduling and become stuck
/// 4. Verify yield vaults are stuck (no active schedules, overdue)
/// 5. Wait more time - yield vaults should remain stuck (no Supervisor to recover them)
/// 6. Verify execution count doesn't increase (stuck yield vaults don't execute)
///
/// This proves that without Supervisor, stuck yield vaults cannot recover.
///
access(all)
fun testFailedYieldVaultCannotRecoverWithoutSupervisor() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Failed yield vault cannot recover without Supervisor")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 2000.0)
    grantBeta(flowYieldVaultsAccount, user)
    
    // Step 1: Create 3 yield vaults
    log("\nStep 1: Creating 3 yield vaults...")
    var i = 0
    while i < 3 {
        let res = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 100.0],
            user
        )
        Test.expect(res, Test.beSucceeded())
        i = i + 1
    }
    
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
    Test.assertEqual(3, yieldVaultIDs.length)
    log("Created 3 yield vaults")
    
    // Track balances for all 3 yield vaults
    var prevBalances: [UFix64] = []
    var idx = 0
    while idx < 3 {
        prevBalances.append(getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0)
        idx = idx + 1
    }
    log("Initial balances: T0=".concat(prevBalances[0].toString()).concat(", T1=").concat(prevBalances[1].toString()).concat(", T2=").concat(prevBalances[2].toString()))
    
    // Step 2: Let them execute 2 rounds (healthy) with balance verification
    log("\nStep 2: Executing 2 rounds (healthy)...")
    var round = 1
    while round <= 2 {
        // Use significant price changes to ensure rebalancing triggers
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0 + (UFix64(round) * 0.3))
        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0 + (UFix64(round) * 0.2))
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        
        // Verify all 3 yield vaults changed balance
        idx = 0
        while idx < 3 {
            let newBal = getAutoBalancerBalance(id: yieldVaultIDs[idx]) ?? 0.0
            Test.assert(newBal != prevBalances[idx], message: "YieldVault ".concat(idx.toString()).concat(" balance should change after round ").concat(round.toString()))
            prevBalances[idx] = newBal
            idx = idx + 1
        }
        log("Round ".concat(round.toString()).concat(" balances verified for all 3 yield vaults"))
        round = round + 1
    }
    
    let eventsBeforeDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions before drain: ".concat(eventsBeforeDrain.length.toString()))
    Test.assert(eventsBeforeDrain.length >= 6, message: "Should have at least 6 executions (3 yield vaults x 2 rounds)")
    
    // Step 3: Drain FLOW from FlowYieldVaults account
    log("\nStep 3: Draining FLOW to cause reschedule failures...")
    let balanceBeforeDrain = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance before drain: ".concat(balanceBeforeDrain.toString()))
    
    // Drain to almost zero (need to leave tiny amount for account minimum)
    // MIN_FEE_FALLBACK is 0.00005, so drain to less than that
    if balanceBeforeDrain > 0.00002 {
        let drainRes = executeTransaction(
            "../transactions/flow-yield-vaults/drain_flow.cdc",
            [balanceBeforeDrain - 0.00001],
            flowYieldVaultsAccount
        )
        Test.expect(drainRes, Test.beSucceeded())
    }
    
    let balanceAfterDrain = (executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    ).returnValue! as! UFix64)
    log("Balance after drain: ".concat(balanceAfterDrain.toString()))
    
    // Step 4: Wait for pre-scheduled transactions to execute (and fail to reschedule)
    // YieldVaults execute every 60s, we need 2-3 rounds for the pre-scheduled txns to complete
    log("\nStep 4: Waiting for pre-scheduled transactions to execute...")
    round = 0
    while round < 3 {
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        round = round + 1
    }
    
    // After yield vaults execute, they try to reschedule but fail due to insufficient funds
    // Now wait at least one MORE interval (60s) so they become overdue
    log("\nStep 4b: Waiting for yield vaults to become overdue (no active schedules)...")
    Test.moveTime(by: 2.0 * (60.0 * 10.0 + 10.0))  // Wait 2 intervals to ensure all yield vaults are past their next expected time
    Test.commitBlock()
    
    let eventsAfterDrain = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after drain+wait: ".concat(eventsAfterDrain.length.toString()))
    
    // Step 5: Check how many yield vaults are stuck (no active schedules + overdue)
    log("\nStep 5: Checking stuck yield vaults...")
    var stuckCount = 0
    for yieldVaultID in yieldVaultIDs {
        let isStuckRes = executeScript("../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc", [yieldVaultID])
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stuckCount = stuckCount + 1
                log("YieldVault ".concat(yieldVaultID.toString()).concat(" is STUCK"))
            }
        }
    }
    log("Stuck yield vaults: ".concat(stuckCount.toString()).concat(" / 3"))
    Test.assert(stuckCount >= 2, message: "At least 2 yield vaults should be stuck after draining funds")
    
    // Record execution count at this point
    let execCountWhenStuck = eventsAfterDrain.length
    
    // Step 6: Wait more time - stuck yield vaults should NOT recover (no Supervisor)
    log("\nStep 6: Waiting more (stuck yield vaults should stay stuck without Supervisor)...")
    round = 0
    while round < 3 {
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        round = round + 1
    }
    
    let eventsFinal = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Final executions: ".concat(eventsFinal.length.toString()))
    
    // Execution count should not have increased much (stuck yield vaults don't execute)
    let newExecutions = eventsFinal.length - execCountWhenStuck
    log("New executions while stuck (without Supervisor): ".concat(newExecutions.toString()))
    
    // Re-check stuck yield vaults
    var stillStuckCount = 0
    for yieldVaultID in yieldVaultIDs {
        let isStuckRes = executeScript("../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc", [yieldVaultID])
        if isStuckRes.returnValue != nil {
            let isStuck = isStuckRes.returnValue! as! Bool
            if isStuck {
                stillStuckCount = stillStuckCount + 1
            }
        }
    }
    log("YieldVaults still stuck: ".concat(stillStuckCount.toString()).concat(" / 3"))
    
    // Stuck yield vaults should remain stuck without Supervisor
    Test.assert(stillStuckCount >= 2, message: "Stuck yield vaults should remain stuck without Supervisor")
    
    log("PASS: Failed yield vaults cannot recover without Supervisor")
}
