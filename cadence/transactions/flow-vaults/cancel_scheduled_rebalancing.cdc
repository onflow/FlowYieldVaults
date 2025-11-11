import "FungibleToken"
import "FlowToken"
import "FlowVaultsScheduler"

/// Cancels a scheduled rebalancing transaction for a specific Tide.
///
/// This transaction cancels a previously scheduled autonomous rebalancing operation
/// and returns a portion of the fees paid (based on the scheduler's refund policy).
///
/// @param tideID: The ID of the Tide whose scheduled rebalancing should be canceled
///
transaction(tideID: UInt64) {
    let schedulerManager: &FlowVaultsScheduler.SchedulerManager
    let flowTokenReceiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the SchedulerManager
        self.schedulerManager = signer.storage
            .borrow<&FlowVaultsScheduler.SchedulerManager>(from: FlowVaultsScheduler.SchedulerManagerStoragePath)
            ?? panic("Could not borrow SchedulerManager from storage. No scheduled rebalancing found.")

        // Get a reference to the signer's FlowToken receiver
        self.flowTokenReceiver = signer.capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow reference to the owner's FlowToken Receiver")
    }

    execute {
        // Cancel the scheduled rebalancing and receive the refund
        let refund <- self.schedulerManager.cancelRebalancing(tideID: tideID)
        
        // Deposit the refund back to the signer's vault
        self.flowTokenReceiver.deposit(from: <-refund)
    }
}

