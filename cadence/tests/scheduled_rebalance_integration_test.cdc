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

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0
access(all) var tideID: UInt64 = 0

access(all)
fun setup() {
    log("Setting up scheduled rebalancing integration test...")
    
    deployContracts()
    
    // Scheduler contracts are deployed as part of deployContracts()
    log("FlowVaultsScheduler available")
    
    // Fund FlowVaults account for scheduling fees
    mintFlow(to: flowVaultsAccount, amount: 1000.0)

    // Set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    log("Mock oracle prices set")

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
    log("Token liquidity setup")

    // Setup FlowCreditMarket with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    log("FlowCreditMarket pool configured")

    // Open wrapped position
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    log("Wrapped position created")

    // Enable mocked Strategy creation
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

/// TEST 1: Native AutoBalancer scheduling and execution
/// 
/// ARCHITECTURE:
/// - Tide creation triggers AutoBalancer initialization with recurringConfig
/// - AutoBalancer self-schedules via FlowTransactionScheduler
/// - Price changes trigger rebalancing on each execution
///
access(all)
fun testNativeScheduledRebalancing() {
    log("\n========================================")
    log("TEST: Native AutoBalancer scheduled rebalancing")
    log("========================================")
    
    let fundingAmount = 1000.0
    let user = Test.createAccount()
    
    // Step 1: Create a Tide with initial funding
    log("Step 1: Creating Tide...")
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
    log("Tide created with ID: ".concat(tideID.toString()))
    
    // Step 2: Verify tide is registered in registry
    log("Step 2: Verifying tide registration...")
    let regIDsRes = executeScript("../scripts/flow-vaults/get_registered_tide_ids.cdc", [])
    Test.expect(regIDsRes, Test.beSucceeded())
    let regIDs = regIDsRes.returnValue! as! [UInt64]
    Test.assert(regIDs.contains(tideID), message: "Tide should be in registry")
    log("Tide is registered in FlowVaultsSchedulerRegistry")
    
    // Step 3: Get initial AutoBalancer balance
    let initialBalance = getAutoBalancerBalance(id: tideID)
    log("Initial AutoBalancer balance: ".concat((initialBalance ?? 0.0).toString()))
    
    // Step 4: Change prices to trigger rebalancing
    log("Step 3: Changing prices...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)
    log("FLOW price changed to 2.0, YieldToken to 1.5")
    
    // Step 5: Wait for automatic execution by emulator FVM
    log("Step 4: Waiting for automatic execution...")
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    // Step 6: Check for execution events
    log("Step 5: Checking for execution events...")
    
    let executionEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    let schedulerExecutedEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    
    log("Events found:")
    log("  DeFiActions.Rebalanced: ".concat(executionEvents.length.toString()))
    log("  Scheduler.Executed: ".concat(schedulerExecutedEvents.length.toString()))
    
    // Verification: Should have at least one scheduler execution
    Test.assert(
        schedulerExecutedEvents.length >= 1,
        message: "Expected at least 1 scheduler execution, found ".concat(schedulerExecutedEvents.length.toString())
    )
    
    // Step 7: Check final balance and assert it changed
    log("Step 6: Checking balance changes...")
    
    let initialBal = initialBalance ?? 0.0
    let finalBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    
    log("Initial AutoBalancer balance: ".concat(initialBal.toString()))
    log("Final AutoBalancer balance: ".concat(finalBalance.toString()))
    log("Balance change: ".concat((finalBalance - initialBal).toString()))
    
    Test.assert(finalBalance != initialBal, message: "Balance should change after rebalancing")
    
    log("PASS: Native scheduled rebalancing")
}

/// TEST 2: Verify multiple executions with price changes
///
access(all)
fun testMultipleExecutionsWithPriceChanges() {
    Test.reset(to: snapshot)
    log("\n========================================")
    log("TEST: Multiple executions with price changes")
    log("========================================")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 500.0)
    grantBeta(flowVaultsAccount, user)
    
    // Step 1: Create Tide
    log("Step 1: Creating Tide...")
    let createTideRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 200.0],
        user
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let myTideID = tideIDs[0]
    log("Tide created: ".concat(myTideID.toString()))
    
    // Track initial state
    let balance0 = getAutoBalancerBalance(id: myTideID) ?? 0.0
    log("Initial balance: ".concat(balance0.toString()))
    
    // Step 2: First execution with price change
    log("Step 2: First execution...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents1 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let balance1 = getAutoBalancerBalance(id: myTideID) ?? 0.0
    log("After execution 1 - Events: ".concat(execEvents1.length.toString()).concat(", Balance: ").concat(balance1.toString()))
    Test.assert(balance1 != balance0, message: "Balance should change after execution 1")
    
    // Step 3: Second execution with price change
    log("Step 3: Second execution...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.5)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 2.0)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents2 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let balance2 = getAutoBalancerBalance(id: myTideID) ?? 0.0
    log("After execution 2 - Events: ".concat(execEvents2.length.toString()).concat(", Balance: ").concat(balance2.toString()))
    Test.assert(balance2 != balance1, message: "Balance should change after execution 2")
    
    // Step 4: Third execution with price change
    log("Step 4: Third execution...")
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 4.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 3.0)
    Test.moveTime(by: 70.0)
    Test.commitBlock()
    
    let execEvents3 = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    let balance3 = getAutoBalancerBalance(id: myTideID) ?? 0.0
    log("After execution 3 - Events: ".concat(execEvents3.length.toString()).concat(", Balance: ").concat(balance3.toString()))
    Test.assert(balance3 != balance2, message: "Balance should change after execution 3")
    
    // Verification: At least 3 executions should have occurred
    Test.assert(
        execEvents3.length >= 3,
        message: "Expected at least 3 scheduler executions, found ".concat(execEvents3.length.toString())
    )
    
    log("PASS: Multiple executions with price changes and verified balance changes")
}

// Main test runner
// Note: getAutoBalancerBalance helper is in test_helpers.cdc
access(all)
fun main() {
    setup()
    testNativeScheduledRebalancing()
    testMultipleExecutionsWithPriceChanges()
}
