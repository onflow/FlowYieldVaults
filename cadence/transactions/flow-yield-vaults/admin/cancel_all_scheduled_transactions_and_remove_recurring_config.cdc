import "FungibleToken"
import "DeFiActions"
import "AutoBalancers"
import "FlowTransactionScheduler"

/// Cancels all scheduled transactions for the AutoBalancer stored at the specified path and removes the recurring config
///
/// @param storagePath: the storage path of the stored AutoBalancer
///
transaction(storagePath: StoragePath) {
    let autoBalancer: auth(AutoBalancers.Configure, FlowTransactionScheduler.Cancel) &AutoBalancers.AutoBalancer
    let refundReceiver: &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue) &Account) {
        self.autoBalancer = signer.storage.borrow<auth(AutoBalancers.Configure, FlowTransactionScheduler.Cancel) &AutoBalancers.AutoBalancer>(from: storagePath)
            ?? panic("AutoBalancer was not found in signer's storage at \(storagePath)")
        // reference the refund receiver
        self.refundReceiver = signer.storage.borrow<&{FungibleToken.Vault}>(from: /storage/flowTokenVault)
            ?? panic("Refund receiver was not found in signer's storage at /storage/flowTokenVault")
    }

    execute {
        // cancel all scheduled transactions
        for id in self.autoBalancer.getScheduledTransactionIDs() {
            if let refund <- self.autoBalancer.cancelScheduledTransaction(id: id) as @{FungibleToken.Vault}? {
                self.refundReceiver.deposit(from: <-refund)
            }
        }
        // remove the recurring config
        self.autoBalancer.setRecurringConfig(nil)
    }
}
