import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "Burner"
import "FlowToken"
import "FungibleToken"

/// Sets the default priority for Supervisor self-rescheduling
///
/// @param priorityRaw: The raw priority value (UInt8) for data serialization (0=High, 1=Medium, 2=Low)
transaction(priorityRaw: UInt8) {

    let supervisor: auth(FlowYieldVaultsSchedulerV1.Configure) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(LoadValue, StorageCapabilities) &Account) {
        self.supervisor = signer.storage.borrow<auth(FlowYieldVaultsSchedulerV1.Configure) &FlowYieldVaultsSchedulerV1.Supervisor>(from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath)
            ?? panic("Could not borrow Supervisor - check FlowYieldVaultsSchedulerV1.ensureSupervisorConfigured()")
    }

    execute {
        self.supervisor.setDefaultPriority(FlowTransactionScheduler.Priority(rawValue: priorityRaw)!)
    }
}
