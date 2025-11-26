import "FlowVaultsScheduler"

/// Manually adds a tide to the pending queue for Supervisor re-seeding.
/// This simulates the scenario where a tide's AutoBalancer failed to self-reschedule.
/// In production, this would be called by a monitoring service that detects failed schedules.
///
/// @param tideID: The ID of the tide to enqueue for re-seeding
///
transaction(tideID: UInt64) {
    let manager: &FlowVaultsScheduler.SchedulerManager

    prepare(signer: auth(BorrowValue) &Account) {
        self.manager = signer.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(
            from: FlowVaultsScheduler.SchedulerManagerStoragePath
        ) ?? panic("SchedulerManager not found. Run setup_scheduler_manager.cdc first.")
    }

    execute {
        self.manager.enqueuePendingTide(tideID: tideID)
    }
}

