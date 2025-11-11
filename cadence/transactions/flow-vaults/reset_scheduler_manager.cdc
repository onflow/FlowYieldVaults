import "FlowVaultsScheduler"

/// Removes the existing SchedulerManager resource from storage, if present.
/// Use only in test environments to clear any leftover scheduled state.
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let path = FlowVaultsScheduler.SchedulerManagerStoragePath
        if let mgr <- signer.storage.load<@FlowVaultsScheduler.SchedulerManager>(from: path) {
            destroy mgr
        }
    }
}


