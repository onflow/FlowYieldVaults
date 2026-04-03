import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "MockStrategies"
import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "AutoBalancers"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@MockStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    log("Setting up batch relaunch + supervisor integration test...")

    deployContracts()
    // Intentionally fund the account without creating /storage/strategiesFeeSource.
    // The batch relaunch transaction is expected to self-heal that capability.
    let fundingFlowYieldVaultsRes = mintFlow(to: flowYieldVaultsAccount, amount: 1000.0)
    Test.expect(fundingFlowYieldVaultsRes, Test.beSucceeded())

    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    let fundingProtocolRes = mintFlow(to: protocolAccount, amount: reserveAmount)
    Test.expect(fundingProtocolRes, Test.beSucceeded())
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        yearlyRate: 0.1,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let openRes = executeTransaction(
        "../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
        [reserveAmount / 2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@MockStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: MockStrategies.IssuerStoragePath,
        beFailed: false
    )

    snapshot = getCurrentBlockHeight()
    Test.commitBlock()
    log("Setup complete")
}

access(all)
fun createYieldVaults(user: Test.TestAccount, count: Int, amount: UFix64): [UInt64] {
    let before = getYieldVaultIDs(address: user.address) ?? []

    var idx = 0
    while idx < count {
        let createRes = executeTransaction(
            "../transactions/flow-yield-vaults/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, amount],
            user
        )
        Test.expect(createRes, Test.beSucceeded())
        idx = idx + 1
    }

    let after = getYieldVaultIDs(address: user.address)!
    let newIDs: [UInt64] = []
    for id in after {
        if !before.contains(id) {
            newIDs.append(id)
        }
    }

    Test.assertEqual(count, newIDs.length)
    return newIDs
}

access(all)
fun hasActiveSchedule(_ yieldVaultID: UInt64): Bool {
    let res = executeScript("../scripts/flow-yield-vaults/has_active_schedule.cdc", [yieldVaultID])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! Bool
}

access(all)
fun isStuckYieldVault(_ yieldVaultID: UInt64): Bool {
    let res = executeScript("../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc", [yieldVaultID])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! Bool
}

access(all)
fun getPendingCount(): Int {
    let res = executeScript("../scripts/flow-yield-vaults/get_pending_count.cdc", [])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! Int
}

access(all)
fun getFlowYieldVaultsFlowBalance(): UFix64 {
    let res = executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! UFix64
}

access(all)
fun drainFlowToResidual(_ residualBalance: UFix64) {
    let balanceBeforeDrain = getFlowYieldVaultsFlowBalance()
    if balanceBeforeDrain > residualBalance {
        let drainRes = executeTransaction(
            "../transactions/flow-yield-vaults/drain_flow.cdc",
            [balanceBeforeDrain - residualBalance],
            flowYieldVaultsAccount
        )
        Test.expect(drainRes, Test.beSucceeded())
    }
}

access(all)
fun waitUntilAllStuck(_ ids: [UInt64], maxRounds: Int): Bool {
    var round = 0
    while round < maxRounds {
        var allStuck = true
        for id in ids {
            if !isStuckYieldVault(id) {
                allStuck = false
            }
        }
        if allStuck {
            return true
        }

        // Each mock auto-balancer is configured for a 10 minute cadence on creation, so advance slightly
        // past that boundary to let failed reschedule attempts surface as stuck state.
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        round = round + 1
    }

    var finalAllStuck = true
    for id in ids {
        if !isStuckYieldVault(id) {
            finalAllStuck = false
        }
    }
    return finalAllStuck
}

access(all)
fun countRebalancedEventsFor(_ yieldVaultID: UInt64): Int {
    var count = 0
    let events = Test.eventsOfType(Type<AutoBalancers.Rebalanced>())
    for eventAny in events {
        let rebalanceEvent = eventAny as! AutoBalancers.Rebalanced
        if rebalanceEvent.uniqueID == yieldVaultID {
            count = count + 1
        }
    }
    return count
}

access(all)
fun scheduleSupervisor(
    recurringInterval: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    scanForStuck: Bool
) {
    let res = executeTransaction(
        "../transactions/flow-yield-vaults/admin/schedule_supervisor.cdc",
        [recurringInterval, priorityRaw, executionEffort, scanForStuck],
        flowYieldVaultsAccount
    )
    Test.expect(res, Test.beSucceeded())
}

access(all)
fun batchRelaunch(
    ids: [UInt64],
    interval: UInt64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    forceRebalance: Bool,
    supervisorRecurringInterval: UFix64,
    supervisorPriorityRaw: UInt8,
    supervisorExecutionEffort: UInt64,
    supervisorScanForStuck: Bool
): Test.TransactionResult {
    return executeTransaction(
        "../transactions/flow-yield-vaults/admin/batch_relaunch_auto_balancers_and_schedule_supervisor.cdc",
        [
            ids,
            interval,
            priorityRaw,
            executionEffort,
            forceRebalance,
            supervisorRecurringInterval,
            supervisorPriorityRaw,
            supervisorExecutionEffort,
            supervisorScanForStuck
        ],
        flowYieldVaultsAccount
    )
}

access(all)
fun testBatchRelaunchHandlesMixedPopulationAndRunningSupervisor() {
    Test.reset(to: snapshot)
    log("\n[TEST] Batch relaunch handles mixed stuck + active vaults with a running supervisor...")

    let user = Test.createAccount()
    let initialUserFundingRes = mintFlow(to: user, amount: 5_000.0)
    Test.expect(initialUserFundingRes, Test.beSucceeded())
    let grantBetaRes = grantBeta(flowYieldVaultsAccount, user)
    Test.expect(grantBetaRes, Test.beSucceeded())

    let stuckIDs = createYieldVaults(user: user, count: 3, amount: 25.0)
    // Drain the scheduler fee balance so the first population loses its ability to keep self-scheduling.
    drainFlowToResidual(0.001)

    Test.assert(waitUntilAllStuck(stuckIDs, maxRounds: 8), message: "Expected initial vaults to become stuck")
    for id in stuckIDs {
        Test.assertEqual(true, isStuckYieldVault(id))
        Test.assertEqual(false, hasActiveSchedule(id))
    }

    let restockFlowYieldVaultsRes = mintFlow(to: flowYieldVaultsAccount, amount: 500.0)
    Test.expect(restockFlowYieldVaultsRes, Test.beSucceeded())

    // Create a second healthy population after restoring FLOW so the batch contains both active and stuck IDs.
    let activeIDs = createYieldVaults(user: user, count: 7, amount: 25.0)
    for id in activeIDs {
        Test.assertEqual(false, isStuckYieldVault(id))
        Test.assertEqual(true, hasActiveSchedule(id))
    }

    let supervisorRescheduledBefore = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.SupervisorRescheduled>()).length
    // Warm up a live supervisor run before invoking the batch transaction so we cover the "already running" case.
    scheduleSupervisor(recurringInterval: 300.0, priorityRaw: 1, executionEffort: 2000, scanForStuck: false)
    Test.moveTime(by: 300.0 + 10.0)
    Test.commitBlock()
    let supervisorRescheduledAfterWarmup = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.SupervisorRescheduled>()).length
    Test.assert(
        supervisorRescheduledAfterWarmup >= supervisorRescheduledBefore + 2,
        message: "Supervisor should schedule and then self-reschedule during warmup"
    )

    for id in stuckIDs {
        Test.assertEqual(true, isStuckYieldVault(id))
    }

    let activeProbe = activeIDs[0]
    let activeProbeRebalancedBefore = countRebalancedEventsFor(activeProbe)

    // Include both a duplicate and a missing ID to verify that the batch skips them without reverting.
    let idsForBatch = stuckIDs.concat(activeIDs).concat([activeProbe, 999_999])
    let batchRes = batchRelaunch(
        ids: idsForBatch,
        interval: 1800,
        priorityRaw: 1,
        executionEffort: 1200,
        forceRebalance: false,
        supervisorRecurringInterval: 900.0,
        supervisorPriorityRaw: 1,
        supervisorExecutionEffort: 5000,
        supervisorScanForStuck: true
    )
    Test.expect(batchRes, Test.beSucceeded())

    let allValidIDs = stuckIDs.concat(activeIDs)
    for id in allValidIDs {
        Test.assertEqual(false, isStuckYieldVault(id))
        Test.assertEqual(true, hasActiveSchedule(id))
    }
    Test.assertEqual(0, getPendingCount())

    // Force a real threshold breach so the post-relaunch execution produces a Rebalanced event rather than a no-op.
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 5.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 4.0)

    Test.moveTime(by: 600.0 + 10.0)
    Test.commitBlock()
    let activeProbeRebalancedMidway = countRebalancedEventsFor(activeProbe)
    Test.assert(
        activeProbeRebalancedBefore == activeProbeRebalancedMidway,
        message: "Active vault should not execute again before the new 1800s interval"
    )

    Test.moveTime(by: 1200.0 + 10.0)
    Test.commitBlock()
    let activeProbeRebalancedAfter = countRebalancedEventsFor(activeProbe)
    Test.assert(
        activeProbeRebalancedAfter > activeProbeRebalancedMidway,
        message: "Active vault should execute after the new 1800s interval elapses"
    )
}

access(all)
fun testBatchRelaunchRecreatesSupervisorWhenDestroyed() {
    Test.reset(to: snapshot)
    log("\n[TEST] Batch relaunch recreates and reschedules the supervisor when it is destroyed...")

    let user = Test.createAccount()
    let recreateUserFundingRes = mintFlow(to: user, amount: 500.0)
    Test.expect(recreateUserFundingRes, Test.beSucceeded())
    let recreateGrantBetaRes = grantBeta(flowYieldVaultsAccount, user)
    Test.expect(recreateGrantBetaRes, Test.beSucceeded())

    let stuckIDs = createYieldVaults(user: user, count: 3, amount: 25.0)
    drainFlowToResidual(0.001)
    Test.assert(waitUntilAllStuck(stuckIDs, maxRounds: 10), message: "Expected test vaults to become stuck")

    let refillFlowYieldVaultsRes = mintFlow(to: flowYieldVaultsAccount, amount: 200.0)
    Test.expect(refillFlowYieldVaultsRes, Test.beSucceeded())

    let destroySupervisorRes = executeTransaction(
        "../transactions/flow-yield-vaults/admin/destroy_supervisor.cdc",
        [],
        flowYieldVaultsAccount
    )
    Test.expect(destroySupervisorRes, Test.beSucceeded())

    let supervisorRescheduledBefore = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.SupervisorRescheduled>()).length

    // The batch transaction should both recover the vault schedules and bootstrap a fresh supervisor run.
    let batchRes = batchRelaunch(
        ids: stuckIDs,
        interval: 1800,
        priorityRaw: 1,
        executionEffort: 1200,
        forceRebalance: false,
        supervisorRecurringInterval: 900.0,
        supervisorPriorityRaw: 1,
        supervisorExecutionEffort: 5000,
        supervisorScanForStuck: true
    )
    Test.expect(batchRes, Test.beSucceeded())

    for yieldVaultID in stuckIDs {
        Test.assertEqual(false, isStuckYieldVault(yieldVaultID))
        Test.assertEqual(true, hasActiveSchedule(yieldVaultID))
    }
    Test.assertEqual(0, getPendingCount())

    let supervisorRescheduledAfterBatch = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.SupervisorRescheduled>()).length
    Test.assert(
        supervisorRescheduledAfterBatch == supervisorRescheduledBefore + 1,
        message: "Batch relaunch should schedule a fresh supervisor run"
    )

    Test.moveTime(by: 900.0 + 10.0)
    Test.commitBlock()

    let supervisorRescheduledAfterExecution = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.SupervisorRescheduled>()).length
    Test.assert(
        supervisorRescheduledAfterExecution > supervisorRescheduledAfterBatch,
        message: "Supervisor should execute and self-reschedule after being recreated"
    )
}
