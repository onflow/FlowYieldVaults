import "FlowVaultsScheduler"

/// Sets up a SchedulerManager in the signer's account storage.
///
/// This transaction initializes the necessary storage for managing scheduled
/// rebalancing transactions. It must be run before scheduling any rebalancing operations.
///
/// Note: This transaction is optional if you use schedule_rebalancing.cdc, which
/// automatically sets up the SchedulerManager if it doesn't exist.
///
transaction() {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        // Check if SchedulerManager already exists
        if signer.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(
            from: FlowVaultsScheduler.SchedulerManagerStoragePath
        ) != nil {
            log("SchedulerManager already exists")
            return
        }

        // Create a new SchedulerManager
        let manager <- FlowVaultsScheduler.createSchedulerManager()
        signer.storage.save(<-manager, to: FlowVaultsScheduler.SchedulerManagerStoragePath)
        
        // Publish public capability
        let cap = signer.capabilities.storage
            .issue<&FlowVaultsScheduler.SchedulerManager>(FlowVaultsScheduler.SchedulerManagerStoragePath)
        signer.capabilities.publish(cap, at: FlowVaultsScheduler.SchedulerManagerPublicPath)

        log("SchedulerManager created successfully")
    }
}

