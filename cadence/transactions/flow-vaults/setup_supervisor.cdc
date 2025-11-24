import "FlowVaultsScheduler"

/// Ensures the global Supervisor handler is configured for the FlowVaults
/// (tidal) account by delegating to the FlowVaultsScheduler contract.
transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        // The actual Supervisor resource and its capability are owned and
        // managed by the FlowVaultsScheduler contract account. This call is
        // idempotent and safe to invoke multiple times.
        FlowVaultsScheduler.ensureSupervisorConfigured()
    }
}


