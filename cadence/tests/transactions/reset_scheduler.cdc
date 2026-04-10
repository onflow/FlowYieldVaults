import FlowTransactionScheduler from "MockFlowTransactionScheduler"

/// Clears all queued/scheduled transactions from the shared scheduler.
transaction {
    prepare(signer: auth(BorrowValue) &Account) {
        let scheduler = signer.storage.borrow<auth(FlowTransactionScheduler.Cancel) &FlowTransactionScheduler.SharedScheduler>(
            from: FlowTransactionScheduler.storagePath
        ) ?? panic("Could not borrow SharedScheduler from signer's storage")

        scheduler.reset()
    }
}
