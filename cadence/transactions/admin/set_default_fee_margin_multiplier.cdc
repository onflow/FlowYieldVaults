import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "Burner"
import "FlowToken"
import "FungibleToken"

/// Sets the default fee margin multiplier for Supervisor self-rescheduling
///
/// @param multiplier: The fee margin multiplier to set
transaction(multiplier: UFix64) {

    let supervisor: auth(FlowYieldVaultsSchedulerV1.Configure) &FlowYieldVaultsSchedulerV1.Supervisor

    prepare(signer: auth(LoadValue, StorageCapabilities) &Account) {
        self.supervisor = signer.storage.borrow<auth(FlowYieldVaultsSchedulerV1.Configure) &FlowYieldVaultsSchedulerV1.Supervisor>(from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath)
            ?? panic("Could not borrow Supervisor - check FlowYieldVaultsSchedulerV1.ensureSupervisorConfigured()")
    }

    execute {
        self.supervisor.setDefaultFeeMarginMultiplier(multiplier)
    }
}
