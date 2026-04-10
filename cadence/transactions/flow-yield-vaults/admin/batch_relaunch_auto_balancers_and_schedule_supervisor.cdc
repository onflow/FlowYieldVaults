import "Burner"
import "FungibleToken"
import "FungibleTokenConnectors"
import "FlowToken"
import "FlowTransactionScheduler"
import "DeFiActions"
import "AutoBalancers"

import "FlowYieldVaultsAutoBalancersV1"
import "FlowYieldVaultsSchedulerV1"

/// Relaunches a batch of AutoBalancers with a new recurring config and ensures the global Supervisor is scheduled.
///
/// For each AutoBalancer ID:
/// - If the AutoBalancer is stuck, its inactive scheduled transaction records are left in place and a new rebalance
///   is seeded immediately after applying the new recurring config.
/// - If the AutoBalancer is not stuck, any live scheduled transactions are cancelled first so the new config can take
///   effect immediately without duplicate scheduled executions.
///
/// Supervisor behavior:
/// - If the Supervisor capability is missing or invalid, the Supervisor is reset and reconfigured.
/// - Regardless of prior state, any currently scheduled Supervisor run is cancelled and a new recurring Supervisor run
///   is scheduled with the provided settings.
///
/// @param ids: The YieldVault / AutoBalancer IDs to relaunch
/// @param interval: The recurring interval for the AutoBalancers in seconds
/// @param priorityRaw: The AutoBalancer priority (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The AutoBalancer execution effort estimate (1-9999)
/// @param forceRebalance: Whether the AutoBalancers should rebalance even when still within their threshold band
/// @param supervisorRecurringInterval: The Supervisor recurring interval in seconds
/// @param supervisorPriorityRaw: The Supervisor priority (0=High, 1=Medium, 2=Low)
/// @param supervisorExecutionEffort: The Supervisor execution effort estimate (1-9999)
/// @param supervisorScanForStuck: Whether the Supervisor should scan for stuck yield vaults on each run
transaction(
    ids: [UInt64],
    interval: UInt64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    forceRebalance: Bool,
    supervisorRecurringInterval: UFix64,
    supervisorPriorityRaw: UInt8,
    supervisorExecutionEffort: UInt64,
    supervisorScanForStuck: Bool
) {
    let autoBalancers: [auth(DeFiActions.Identify, AutoBalancers.Configure, AutoBalancers.Schedule, FlowTransactionScheduler.Cancel) &AutoBalancers.AutoBalancer]
    let autoBalancerIDs: [UInt64]
    let fundingVault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>
    let refundReceiver: &{FungibleToken.Vault}
    let oldSupervisor: @FlowYieldVaultsSchedulerV1.Supervisor?
    let supervisor: auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(BorrowValue, CopyValue, LoadValue, SaveValue, StorageCapabilities) &Account) {
        pre {
            interval > 0: "interval must be greater than 0"
            executionEffort > 0: "executionEffort must be greater than 0"
            supervisorRecurringInterval > 0.0: "supervisorRecurringInterval must be greater than 0"
            supervisorExecutionEffort > 0: "supervisorExecutionEffort must be greater than 0"
        }

        self.autoBalancers = []
        self.autoBalancerIDs = []

        var seen: {UInt64: Bool} = {}
        for id in ids {
            // A batch run should tolerate duplicates instead of making the caller sanitize the list first.
            if seen[id] == true {
                log("Skipping duplicate AutoBalancer id \(id)")
                continue
            }
            seen[id] = true

            let storagePath = FlowYieldVaultsAutoBalancersV1.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
            let autoBalancer = signer.storage
                .borrow<auth(DeFiActions.Identify, AutoBalancers.Configure, AutoBalancers.Schedule, FlowTransactionScheduler.Cancel) &AutoBalancers.AutoBalancer>(from: storagePath)
            // Missing IDs are logged and skipped so the rest of the batch can still be repaired.
            if autoBalancer == nil {
                log("Skipping missing AutoBalancer id \(id) at path \(storagePath)")
                continue
            }

            self.autoBalancers.append(autoBalancer!)
            self.autoBalancerIDs.append(id)
        }

        let fundingVaultStoragePath = /storage/strategiesFeeSource
        var fundingVault = signer.storage
            .copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: fundingVaultStoragePath)

        // Admin accounts on older deployments may not have the fee-source capability saved yet, or may
        // hold a stale one. Rebuild it from /storage/flowTokenVault so the batch transaction is self-healing.
        if fundingVault == nil || !fundingVault!.check() {
            let _ = signer.storage
                .load<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: fundingVaultStoragePath)
            let issuedFundingVault = signer.capabilities.storage
                .issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
            signer.storage.save(issuedFundingVault, to: fundingVaultStoragePath)
            fundingVault = signer.storage
                .copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: fundingVaultStoragePath)
        }

        self.fundingVault = fundingVault
            ?? panic("Could not find or create funding vault Capability at /storage/strategiesFeeSource")

        self.refundReceiver = signer.storage
            .borrow<&{FungibleToken.Vault}>(from: /storage/flowTokenVault)
            ?? panic("Refund receiver was not found in signer's storage at /storage/flowTokenVault")

        let supervisorCapabilityStoragePath = /storage/FlowYieldVaultsSupervisorCapability
        let supervisorStoragePath = FlowYieldVaultsSchedulerV1.SupervisorStoragePath

        let supervisorExists = signer.storage.type(at: supervisorStoragePath) != nil
        let storedSupervisorCap = signer.storage
            .copy<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                from: supervisorCapabilityStoragePath
            )
        var oldSupervisor: @FlowYieldVaultsSchedulerV1.Supervisor? <- nil

        // If the saved capability is stale, remove the broken capability state and rebuild the resource
        // via ensureSupervisorConfigured() below.
        if storedSupervisorCap != nil && !storedSupervisorCap!.check() {
            let _ = signer.storage
                .load<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                    from: supervisorCapabilityStoragePath
                )

            for controller in signer.capabilities.storage.getControllers(forPath: supervisorStoragePath) {
                controller.delete()
            }

            if supervisorExists {
                oldSupervisor <-! signer.storage.load<@FlowYieldVaultsSchedulerV1.Supervisor>(from: supervisorStoragePath)
            }

            if let supervisorRef = &oldSupervisor as auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor? {
                Burner.burn(<-supervisorRef.cancelScheduledTransaction(refundReceiver: nil))
            }
        }

        self.oldSupervisor <- oldSupervisor

        FlowYieldVaultsSchedulerV1.ensureSupervisorConfigured()

        self.supervisor = signer.storage
            .borrow<auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor>(from: supervisorStoragePath)
            ?? panic("Could not borrow Supervisor at \(supervisorStoragePath)")
    }

    execute {
        let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
            ?? panic("Invalid AutoBalancer priority: \(priorityRaw) - must be 0=High, 1=Medium, 2=Low")
        let supervisorPriority = FlowTransactionScheduler.Priority(rawValue: supervisorPriorityRaw)
            ?? panic("Invalid Supervisor priority: \(supervisorPriorityRaw) - must be 0=High, 1=Medium, 2=Low")

        var index = 0
        while index < self.autoBalancers.length {
            let id = self.autoBalancerIDs[index]
            let autoBalancer = self.autoBalancers[index]
            let isStuck = FlowYieldVaultsAutoBalancersV1.isStuckYieldVault(id: id)

            if !isStuck {
                var cancelledCount = 0
                for txnID in autoBalancer.getScheduledTransactionIDs() {
                    let txn = autoBalancer.borrowScheduledTransaction(id: txnID)
                    // Only live Scheduled entries are canceled. Stuck vaults keep their historical records and
                    // simply receive a new seeded schedule.
                    if txn?.status() == FlowTransactionScheduler.Status.Scheduled {
                        if let refund <- autoBalancer.cancelScheduledTransaction(id: txnID) as @{FungibleToken.Vault}? {
                            self.refundReceiver.deposit(from: <-refund)
                        }
                        cancelledCount = cancelledCount + 1
                    }
                }
                if cancelledCount > 0 {
                    log("Cancelled \(cancelledCount) scheduled transaction(s) for AutoBalancer \(id)")
                }
            }

            var txnFunder = FungibleTokenConnectors.VaultSinkAndSource(
                min: nil,
                max: nil,
                vault: self.fundingVault,
                uniqueID: nil
            )

            DeFiActions.alignID(
                toUpdate: &txnFunder as auth(DeFiActions.Extend) &{DeFiActions.IdentifiableStruct},
                with: autoBalancer
            )

            let config = AutoBalancers.AutoBalancerRecurringConfig(
                interval: interval,
                priority: priority,
                executionEffort: executionEffort,
                forceRebalance: forceRebalance,
                txnFunder: txnFunder
            )

            autoBalancer.setRecurringConfig(config)

            // A single AutoBalancer that still cannot be scheduled should not abort the whole repair batch.
            if let err = autoBalancer.scheduleNextRebalance(whileExecuting: nil) {
                log("Failed to schedule next rebalance for AutoBalancer \(id): \(err)")
                index = index + 1
                continue
            }

            index = index + 1
        }

        // Always replace the supervisor run so the batch leaves a single authoritative recurring schedule behind.
        Burner.burn(<-self.supervisor.cancelScheduledTransaction(refundReceiver: nil))

        self.supervisor.scheduleNextRecurringExecution(
            recurringInterval: supervisorRecurringInterval,
            priority: supervisorPriority,
            executionEffort: supervisorExecutionEffort,
            scanForStuck: supervisorScanForStuck
        )

        Burner.burn(<-self.oldSupervisor)
    }
}
