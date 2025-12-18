import "FungibleToken"
import "DeFiActions"
import "FlowTransactionScheduler"

/// Cancels all scheduled transactions for the AutoBalancer stored at the specified path and removes the recurring config
///
/// @param storagePath: the storage path of the stored AutoBalancer
///
transaction(storagePath: StoragePath) {
    let autoBalancer: auth(DeFiActions.Configure, FlowTransactionScheduler.Cancel) &DeFiActions.AutoBalancer
    let refundReceiver: &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue) &Account) {
        self.autoBalancer = signer.storage.borrow<auth(DeFiActions.Configure, FlowTransactionScheduler.Cancel) &DeFiActions.AutoBalancer>(from: storagePath)
            ?? panic("AutoBalancer was not found in signer's storage at \(storagePath)")
        // reference the refund receiver
        self.refundReceiver = signer.storage.borrow<&{FungibleToken.Vault}>(from: /storage/flowTokenVault)
            ?? panic("Refund receiver was not found in signer's storage at /storage/flowTokenVault")
    }

    execute {
        // cancel all scheduled transactions
        for id in self.autoBalancer.getScheduledTransactionIDs() {
            let refund <- self.autoBalancer.cancelScheduledTransaction(id: id) as @{FungibleToken.Vault}?
            if refund != nil {
                self.refundReceiver.deposit(from: <-refund!)
            } else {
                destroy refund
            }
        }
        // remove the recurring config
        self.autoBalancer.setRecurringConfig(nil)
    }
}
