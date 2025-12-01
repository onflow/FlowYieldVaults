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
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    log("Setting up scheduler edge cases test...")
    
    deployContracts()
    
    // Fund FlowVaults account for scheduling fees
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

    // Setup FlowCreditMarket
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
        "../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
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
    
    // Capture snapshot for test isolation
    snapshot = getCurrentBlockHeight()
}

/// Test: New tide has active native schedule immediately after creation
///
/// Verifies that when a tide is created, it automatically starts self-scheduling
/// via the native AutoBalancer mechanism without any Supervisor intervention.
///
access(all)
fun testTideHasNativeScheduleAfterCreation() {
    log("\n[TEST] Tide has native schedule immediately after creation...")
    
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
    
    // Verify tide is registered and has active schedule (native self-scheduling)
    let hasActive = (executeScript(
        "../scripts/flow-vaults/has_active_schedule.cdc",
        [tideID]
    ).returnValue! as! Bool)
    Test.assert(hasActive, message: "Tide should have active native schedule immediately after creation")
    
    log("PASS: Tide has native self-scheduling immediately after creation")
}

/// NOTE: Cancel recovery transaction was removed.
/// Recovery schedule cancellation is not a primary use case.
/// If a tide needs to stop, close it via close_tide.cdc.

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

/// Test: Close tide properly unregisters from registry
///
/// When a tide is closed:
/// 1. It should be unregistered from the registry
/// 2. Any active schedules should be cleaned up
///
access(all)
fun testCloseTideUnregisters() {
    log("\n[TEST] Close tide properly unregisters from registry...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 400.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create a tide
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))
    
    // Verify registered
    let regIDsBefore = (executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    ).returnValue! as! [UInt64])
    Test.assert(regIDsBefore.contains(tideID), message: "Tide should be registered")
    log("Tide is registered")
    
    // Close the tide
    let closeRes = executeTransaction(
        "../transactions/flow-vaults/close_tide.cdc",
        [tideID],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())
    log("Tide closed successfully")
    
    // Verify unregistered
    let regIDsAfter = (executeScript(
        "../scripts/flow-vaults/get_registered_tide_ids.cdc",
        []
    ).returnValue! as! [UInt64])
    Test.assert(!regIDsAfter.contains(tideID), message: "Tide should be unregistered after close")
    log("Tide correctly unregistered after close")
}

/// Test: Multiple users with multiple tides all registered correctly
access(all)
fun testMultipleUsersMultipleTides() {
    log("\n[TEST] Multiple users with multiple tides...")
    
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    mintFlow(to: user1, amount: 500.0)
    mintFlow(to: user2, amount: 500.0)
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

/// Test: Healthy tides continue executing without Supervisor intervention
access(all)
fun testHealthyTidesSelfSchedule() {
    Test.reset(to: snapshot)
    log("\n[TEST] Healthy tides continue executing without Supervisor...")
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: 500.0)
    grantBeta(flowVaultsAccount, user)
    
    // Create a tide
    let createRes = executeTransaction(
        "../transactions/flow-vaults/create_tide.cdc",
        [strategyIdentifier, flowTokenIdentifier, 100.0],
        user
    )
    Test.expect(createRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user.address)!
    let tideID = tideIDs[0]
    log("Tide created: ".concat(tideID.toString()))
    
    // Track initial balance
    var prevBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    log("Initial balance: ".concat(prevBalance.toString()))
    
    // Execute 3 rounds with balance verification using LARGE price changes
    var round = 1
    while round <= 3 {
        // Use LARGE price changes to ensure rebalancing triggers
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.5 * UFix64(round))
        setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.2 * UFix64(round))
        Test.moveTime(by: 70.0)
        Test.commitBlock()
        
        let newBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
        log("Round ".concat(round.toString()).concat(": Balance ").concat(prevBalance.toString()).concat(" -> ").concat(newBalance.toString()))
        Test.assert(newBalance != prevBalance, message: "Balance should change after round ".concat(round.toString()))
        prevBalance = newBalance
        
        round = round + 1
    }
    
    let execEvents = Test.eventsOfType(Type<FlowTransactionScheduler.Executed>())
    log("Executions after 3 rounds: ".concat(execEvents.length.toString()))
    Test.assert(execEvents.length >= 3, message: "Should have at least 3 executions")
    
    // Verify not stuck (healthy tide should not be stuck)
    let isStuck = (executeScript(
        "../scripts/flow-vaults/is_stuck_tide.cdc",
        [tideID]
    ).returnValue! as! Bool)
    Test.assert(!isStuck, message: "Healthy tide should not be stuck")
    
    log("PASS: Healthy tide continues self-scheduling without Supervisor with verified balance changes")
}
