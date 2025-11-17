import "FlowVaultsScheduler"
import "FlowVaultsSchedulerRegistry"
import "FlowTransactionScheduler"

/// Creates and stores the global Supervisor handler in the FlowVaults (tidal) account.
transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        let path = FlowVaultsScheduler.deriveSupervisorPath()
        if signer.storage.borrow<&FlowVaultsScheduler.Supervisor>(from: path) == nil {
            let sup <- FlowVaultsScheduler.createSupervisor()
            signer.storage.save(<-sup, to: path)
        }
        // Publish supervisor capability for self-rescheduling
        let supCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(path)
        FlowVaultsSchedulerRegistry.setSupervisorCap(cap: supCap)
    }
}


