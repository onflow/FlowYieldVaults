import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "Burner"
import "FlowToken"
import "FungibleToken"

/// Destroys the global Supervisor, removing the stored Capability used for scheduling and cancelling any scheduled 
/// transactions internally managed by the Supervisor. After removing old Supervisor, it schedules a new one for 
/// recurring execution. Configurable via arguments; sensible defaults if omitted.
///
/// - recurringInterval: seconds between runs (e.g., 60.0)
/// - priorityRaw: The raw priority value (UInt8) for data serialization (0=High, 1=Medium, 2=Low)
/// - executionEffort: The execution effort estimate for the transaction (1-9999)
/// - scanForStuck: Whether to scan for stuck yield vaults in the next execution
transaction(
    recurringInterval: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    scanForStuck: Bool
) {

    let oldSupervisor: @FlowYieldVaultsSchedulerV1.Supervisor?
    let newSupervisor: auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(LoadValue, StorageCapabilities) &Account) {
        // remove the stored Capability used for internal recurring execution
        let supervisorCap = signer.storage
            .load<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                from: /storage/FlowYieldVaultsSupervisorCapability
            )
        // delete all controllers for the Supervisor storage path
        for controller in signer.capabilities.storage.getControllers(forPath: FlowYieldVaultsSchedulerV1.SupervisorStoragePath) {
            controller.delete()
        }
        // load the old Supervisor
        self.oldSupervisor <- signer.storage.load<@FlowYieldVaultsSchedulerV1.Supervisor>(from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath)
        // cancel the scheduled transaction - deposits refund to the supervisor.feesCap
        if let ref = &self.oldSupervisor as auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor? {
            Burner.burn(<-ref.cancelScheduledTransaction(refundReceiver: nil))
        }
        // reconfigure a new Supervisor
        FlowYieldVaultsSchedulerV1.ensureSupervisorConfigured()

        // borrow the new Supervisor to schedule the next recurring execution
        self.newSupervisor = signer.storage.borrow<auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor>(
                from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath
            ) ?? panic("Could not borrow new Supervisor - check FlowYieldVaultsSchedulerV1.ensureSupervisorConfigured()")
    }

    execute {
        Burner.burn(<-self.oldSupervisor)
        self.newSupervisor.scheduleNextRecurringExecution(
            recurringInterval: recurringInterval,
            priority: FlowTransactionScheduler.Priority.Medium,
            priorityRaw: priorityRaw,
            executionEffort: executionEffort,
            scanForStuck: scanForStuck
        )
    }
}
