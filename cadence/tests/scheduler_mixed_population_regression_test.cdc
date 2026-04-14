/// Mixed-population regression tests for the scheduler stuck-scan.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// The Supervisor does not scan the full registry for stuck vaults. Each run only asks the
/// registry for up to MAX_BATCH_SIZE candidates from the tail of the scan order, then checks
/// those candidates one by one.
///
/// That optimization breaks down when the scan order contains stale entries that can never
/// become stuck. In particular, vaults that were once recurring can remain in the ordering
/// after their recurring config is removed, even though isStuckYieldVault() immediately
/// returns false for them.
///
/// This creates a liveness risk:
/// - more than MAX_BATCH_SIZE non-recurring vaults can occupy the tail,
/// - the Supervisor can keep rescanning those same ineligible IDs,
/// - and a real stuck recurring vault further up the list is never detected or recovered.
///
/// This file exists to lock that failure mode down as a regression. The main test below
/// intentionally builds that mixed population and asserts the Supervisor should still find
/// the real stuck vault after bounded lazy pruning advances through the stale tail entries.
import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "MockStrategies"
import "FlowYieldVaultsAutoBalancers"
import "FlowYieldVaultsSchedulerV1"
import "FlowYieldVaultsSchedulerRegistry"

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
    log("Setting up mixed-population scheduler regression test...")

    deployContracts()
    let _mintedFlowToVaultsAccount = mintFlow(to: flowYieldVaultsAccount, amount: 1000.0)

    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    let _mintedFlowToProtocol = mintFlow(to: protocolAccount, amount: reserveAmount)
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
        yearlyRate: UFix128(0.1),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let openRes = _executeTransaction(
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
    log("Setup complete")
}

access(all)
fun cancelSchedulesAndRemoveRecurringConfig(yieldVaultID: UInt64) {
    let storagePath = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(
        id: yieldVaultID,
        storage: true
    ) as! StoragePath
    let res = _executeTransaction(
        "../transactions/admin/cancel_all_scheduled_transactions_and_remove_recurring_config.cdc",
        [storagePath],
        flowYieldVaultsAccount
    )
    Test.expect(res, Test.beSucceeded())
}

access(all)
fun isStuckYieldVault(_ yieldVaultID: UInt64): Bool {
    let res = _executeScript("../scripts/flow-yield-vaults/is_stuck_yield_vault.cdc", [yieldVaultID])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! Bool
}

access(all)
fun hasActiveSchedule(_ yieldVaultID: UInt64): Bool {
    let res = _executeScript("../scripts/flow-yield-vaults/has_active_schedule.cdc", [yieldVaultID])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! Bool
}

access(all)
fun getFlowYieldVaultsFlowBalance(): UFix64 {
    let res = _executeScript(
        "../scripts/flow-yield-vaults/get_flow_balance.cdc",
        [flowYieldVaultsAccount.address]
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! UFix64
}

/// Regression test: more than MAX_BATCH_SIZE non-recurring registry entries must not
/// permanently starve stuck recurring vault detection.
///
/// Setup:
/// 1. Create MAX_BATCH_SIZE + 1 mock vaults and strip their recurring config/schedules.
/// 2. Create one real recurring vault after them so it sits behind those tail entries.
/// 3. Drain FLOW so that recurring vault executes once but fails to reschedule, becoming stuck.
/// 4. Fund and run the Supervisor for several ticks.
///
/// Expected behavior:
/// - The recurring vault is eventually detected and recovered.
/// - The non-recurring tail entries do not block recovery forever.
access(all)
fun testSupervisorScansPastNonRecurringTailEntries() {
    if snapshot != getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }
    log("\n[TEST] Supervisor scans past non-recurring tail entries...")

    let blockerCount = FlowYieldVaultsSchedulerRegistry.MAX_BATCH_SIZE + 1
    let user = Test.createAccount()
    let _mintedFlowToUser = mintFlow(to: user, amount: 2000.0)
    let _grantedBetaToUser = grantBeta(flowYieldVaultsAccount, user)

    // Step 1: create more than one full scan batch of normal recurring mock vaults.
    // We will convert these into permanently ineligible "blockers" without removing them
    // from the registry, so they keep occupying the tail of the scan order.
    var idx = 0
    while idx < blockerCount {
        let createRes = _executeTransaction(
            "../transactions/create_yield_vault.cdc",
            [strategyIdentifier, flowTokenIdentifier, 25.0],
            user
        )
        Test.expect(createRes, Test.beSucceeded())
        idx = idx + 1
    }

    let blockerIDs = getYieldVaultIDs(address: user.address)!
    Test.assertEqual(blockerCount, blockerIDs.length)

    // Step 2: strip schedules and recurring config from those vaults. They stay registered,
    // but they can no longer self-schedule and they can never satisfy isStuckYieldVault().
    for blockerID in blockerIDs {
        cancelSchedulesAndRemoveRecurringConfig(yieldVaultID: blockerID)
        Test.assertEqual(false, hasActiveSchedule(blockerID))
        Test.assertEqual(false, isStuckYieldVault(blockerID))
    }
    log("Prepared \(blockerCount.toString()) non-recurring registry entries at the tail")

    // Step 3: create one real recurring vault after the blockers. This vault is the one we
    // will intentionally push into a stuck state and expect the Supervisor to recover.
    let targetRes = _executeTransaction(
        "../transactions/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, 25.0],
        user
    )
    Test.expect(targetRes, Test.beSucceeded())

    let allYieldVaultIDs = getYieldVaultIDs(address: user.address)!
    var recurringYieldVaultID: UInt64 = 0
    var foundRecurringTarget = false
    for yieldVaultID in allYieldVaultIDs {
        if !blockerIDs.contains(yieldVaultID) {
            recurringYieldVaultID = yieldVaultID
            foundRecurringTarget = true
        }
    }
    Test.assert(foundRecurringTarget, message: "Failed to identify the recurring target yield vault")
    Test.assertEqual(true, hasActiveSchedule(recurringYieldVaultID))

    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.5)

    // Step 4: drain the shared FLOW fee vault to the minimum possible residual balance.
    // The target vault already has its first schedule funded, so it should execute once and
    // then eventually stop self-scheduling, making it a genuine stuck recurring vault.
    let balanceBeforeDrain = getFlowYieldVaultsFlowBalance()
    let residualBalance = 0.00000001
    if balanceBeforeDrain > residualBalance {
        let drainRes = _executeTransaction(
            "transactions/drain_flow.cdc",
            [balanceBeforeDrain - residualBalance],
            flowYieldVaultsAccount
        )
        Test.expect(drainRes, Test.beSucceeded())
    }

    // Give the already-funded first execution time to run, then keep advancing until the
    // vault becomes overdue with no active schedule. A nearly-empty fee vault can still be
    // enough for one extra scheduling attempt, so this waits several intervals.
    idx = 0
    while idx < 6 && !isStuckYieldVault(recurringYieldVaultID) {
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        idx = idx + 1
    }

    Test.assertEqual(true, isStuckYieldVault(recurringYieldVaultID))
    Test.assertEqual(false, hasActiveSchedule(recurringYieldVaultID))

    // Step 5: fund the account again and start the Supervisor. A correct implementation
    // should eventually scan past the blockers, detect the real stuck recurring vault, and
    // recover it.
    let _mintedFlowForRecovery = mintFlow(to: flowYieldVaultsAccount, amount: 200.0)
    Test.commitBlock()

    let recoveredEventsBefore = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.YieldVaultRecovered>()).length
    let detectedEventsBefore = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.StuckYieldVaultDetected>()).length

    let scheduleSupervisorRes = _executeTransaction(
        "../transactions/admin/schedule_supervisor.cdc",
        [60.0 * 10.0, UInt8(1), UInt64(800), true],
        flowYieldVaultsAccount
    )
    Test.expect(scheduleSupervisorRes, Test.beSucceeded())

    // First Supervisor tick should spend its bounded inspection budget pruning the non-recurring
    // blocker tail. It should not reach the stuck recurring target yet.
    Test.moveTime(by: 60.0 * 10.0 + 10.0)
    Test.commitBlock()

    var recoveredEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.YieldVaultRecovered>())
    var detectedEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.StuckYieldVaultDetected>())
    Test.assert(
        detectedEvents.length == detectedEventsBefore,
        message: "First Supervisor tick should only prune blocker tail entries, not detect the recurring target yet"
    )
    Test.assert(
        recoveredEvents.length == recoveredEventsBefore,
        message: "First Supervisor tick should not recover the recurring target yet"
    )

    // Subsequent bounded scans should make forward progress and eventually reach the real
    // stuck recurring vault behind the stale tail.
    let remainingSupervisorTicks = 2
    idx = 0
    while idx < remainingSupervisorTicks
        && detectedEvents.length == detectedEventsBefore
        && recoveredEvents.length == recoveredEventsBefore {
        Test.moveTime(by: 60.0 * 10.0 + 10.0)
        Test.commitBlock()
        recoveredEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.YieldVaultRecovered>())
        detectedEvents = Test.eventsOfType(Type<FlowYieldVaultsSchedulerV1.StuckYieldVaultDetected>())
        idx = idx + 1
    }

    log("Recovered events after supervisor ticks: \(recoveredEvents.length.toString())")
    log("Detected events after supervisor ticks: \(detectedEvents.length.toString())")

    // These are the core regression assertions. A correct implementation should prune through
    // the stale non-recurring tail over repeated bounded scans, then detect and recover the
    // real recurring vault behind it.
    Test.assert(
        detectedEvents.length > detectedEventsBefore,
        message: "Supervisor should eventually detect the stuck recurring vault instead of rescanning the same non-recurring tail entries forever"
    )
    Test.assert(
        recoveredEvents.length > recoveredEventsBefore,
        message: "Supervisor should eventually recover the stuck recurring vault even when more than MAX_BATCH_SIZE non-recurring entries occupy the tail"
    )
    Test.assertEqual(false, isStuckYieldVault(recurringYieldVaultID))
    Test.assertEqual(true, hasActiveSchedule(recurringYieldVaultID))
}
