import "FungibleToken"
import "FlowToken"
import "FlowTransactionScheduler"
import "FlowVaultsScheduler"
import "FlowVaultsSchedulerRegistry"

/// Schedules an autonomous rebalancing transaction for a specific Tide.
///
/// This transaction allows users to schedule periodic or one-time rebalancing operations
/// for their Tides using Flow's native transaction scheduler. The scheduled transaction
/// will automatically rebalance the Tide's AutoBalancer at the specified time(s).
///
/// Note: This transaction uses the Registry to fetch the wrapper capability, allowing any user
/// to schedule rebalancing for a Tide if they pay the fees.
///
/// @param tideID: The ID of the Tide to schedule rebalancing for
/// @param timestamp: The Unix timestamp when the first rebalancing should occur (must be in the future)
/// @param priorityRaw: The priority level as a UInt8 (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The computational effort to allocate (affects fee, typical: 100-1000)
/// @param feeAmount: The amount of FLOW tokens to pay for scheduling (use estimate script first)
/// @param force: If true, rebalance regardless of thresholds; if false, only rebalance when needed
/// @param isRecurring: If true, schedule recurring rebalancing at regular intervals
/// @param recurringInterval: If recurring, the number of seconds between rebalancing operations (e.g., 86400 for daily)
///
transaction(
    tideID: UInt64,
    timestamp: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    feeAmount: UFix64,
    force: Bool,
    isRecurring: Bool,
    recurringInterval: UFix64?
) {
    let schedulerManager: &FlowVaultsScheduler.SchedulerManager
    let paymentVault: @FlowToken.Vault
    let wrapperCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        // Get or create the SchedulerManager
        if signer.storage.borrow<&FlowVaultsScheduler.SchedulerManager>(
            from: FlowVaultsScheduler.SchedulerManagerStoragePath
        ) == nil {
            // Create a new SchedulerManager if one doesn't exist
            let manager <- FlowVaultsScheduler.createSchedulerManager()
            signer.storage.save(<-manager, to: FlowVaultsScheduler.SchedulerManagerStoragePath)
            
            // Publish public capability
            let cap = signer.capabilities.storage
                .issue<&FlowVaultsScheduler.SchedulerManager>(FlowVaultsScheduler.SchedulerManagerStoragePath)
            signer.capabilities.publish(cap, at: FlowVaultsScheduler.SchedulerManagerPublicPath)
        }

        // Borrow the SchedulerManager
        self.schedulerManager = signer.storage
            .borrow<&FlowVaultsScheduler.SchedulerManager>(from: FlowVaultsScheduler.SchedulerManagerStoragePath)
            ?? panic("Could not borrow SchedulerManager from storage")

        // Get the wrapper capability from the Registry
        self.wrapperCap = FlowVaultsSchedulerRegistry.getWrapperCap(tideID: tideID)
            ?? panic("No wrapper capability found for Tide #".concat(tideID.toString()).concat(". Is it registered?"))

        // Withdraw payment from the signer's FlowToken vault
        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow reference to the owner's FlowToken Vault")
        
        self.paymentVault <- vaultRef.withdraw(amount: feeAmount) as! @FlowToken.Vault
    }

    execute {
        // Convert the raw priority value to the enum
        let priority: FlowTransactionScheduler.Priority = priorityRaw == 0 
            ? FlowTransactionScheduler.Priority.High
            : (priorityRaw == 1 
                ? FlowTransactionScheduler.Priority.Medium 
                : FlowTransactionScheduler.Priority.Low)

        // Schedule the rebalancing
        self.schedulerManager.scheduleRebalancing(
            handlerCap: self.wrapperCap,
            tideID: tideID,
            timestamp: timestamp,
            priority: priority,
            executionEffort: executionEffort,
            fees: <-self.paymentVault,
            force: force,
            isRecurring: isRecurring,
            recurringInterval: recurringInterval
        )
    }
}
