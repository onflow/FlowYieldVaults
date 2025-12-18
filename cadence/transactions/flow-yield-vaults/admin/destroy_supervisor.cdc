import "FlowYieldVaultsSchedulerV1"
import "FlowTransactionScheduler"
import "Burner"
import "FlowToken"
import "FungibleToken"

/// Destroys the global Supervisor, removing the stored Capability used for scheduling and cancelling any scheduled 
/// transactions internally managed by the Supervisor.
transaction {

    let supervisor: @FlowYieldVaultsSchedulerV1.Supervisor?

    prepare(signer: auth(LoadValue, StorageCapabilities) &Account) {
        let supervisorCap = signer.storage
            .load<Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>>(
                from: /storage/FlowYieldVaultsSupervisorCapability
            )
        for controller in signer.capabilities.storage.getControllers(forPath: FlowYieldVaultsSchedulerV1.SupervisorStoragePath) {
            controller.delete()
        }
        self.supervisor <- signer.storage.load<@FlowYieldVaultsSchedulerV1.Supervisor>(from: FlowYieldVaultsSchedulerV1.SupervisorStoragePath)
        if let ref = &self.supervisor as auth(FlowYieldVaultsSchedulerV1.Schedule) &FlowYieldVaultsSchedulerV1.Supervisor? {
            Burner.burn(<-ref.cancelScheduledTransaction(refundReceiver: nil))
        }
    }

    execute {
        Burner.burn(<-self.supervisor)
    }
}
