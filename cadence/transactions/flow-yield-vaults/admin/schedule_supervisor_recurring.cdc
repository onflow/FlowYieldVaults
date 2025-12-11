import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"

/// Admin transaction to kick off scheduled transactions for FlowYieldVaults
/// by calling scheduleNextRecurringExecution on the Supervisor with default parameters.
///
/// This transaction must be signed by the contract account that owns the Supervisor resource.
/// It uses the default parameters from FlowYieldVaultsSchedulerV1:
/// - recurringInterval: 60.0 seconds
/// - priority: Medium (1)
/// - executionEffort: 800
/// - scanForStuck: true
///
transaction {
    let supervisorRef: auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the Supervisor resource with Schedule entitlement from the contract account storage
        self.supervisorRef = signer.storage.borrow<auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor>(
            from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath
        ) ?? panic("Supervisor not found at expected storage path")
    }

    execute {
        // Call scheduleNextRecurringExecution with default parameters
        self.supervisorRef.scheduleNextRecurringExecution(
            recurringInterval: FlowYieldVaultsSchedulerV1.DEFAULT_RECURRING_INTERVAL,
            priority: FlowTransactionScheduler.Priority.Medium,
            priorityRaw: FlowYieldVaultsSchedulerV1.DEFAULT_PRIORITY,
            executionEffort: FlowYieldVaultsSchedulerV1.DEFAULT_EXECUTION_EFFORT,
            scanForStuck: true
        )
    }
}

