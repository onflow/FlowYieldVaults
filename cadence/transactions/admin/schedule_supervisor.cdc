import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "FlowToken"
import "FungibleToken"

/// Schedules the global Supervisor for recurring execution via its internal self-scheduling mechanism.
///
/// @param recurringInterval: seconds between runs (e.g., 60.0)
/// @param priorityRaw: The raw priority value (UInt8) for data serialization (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The execution effort estimate for the transaction (1-9999)
/// @param scanForStuck: Whether to scan for stuck yield vaults in the next execution
transaction(
    recurringInterval: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    scanForStuck: Bool
) {
    let supervisor: auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(BorrowValue) &Account) {
        // Obtain the global Supervisor reference from storage
        self.supervisor = signer.storage.borrow<auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor>(
                from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath
            ) ?? panic("Could not reference FlowYieldVaultsSupervisorCapability from \(FlowYieldVaultsSchedulerV1.SupervisorStoragePath)")
    }

    execute {
        let prio = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
            ?? panic("Invalid priority \(priorityRaw) - valid raw values are 0=High,1=Medium,2=Low")

        self.supervisor.scheduleNextRecurringExecution(
            recurringInterval: recurringInterval,
            priority: prio,
            executionEffort: executionEffort,
            scanForStuck: scanForStuck
        )
    }
}
