import "FungibleToken"
import "FlowToken"
import "FlowTransactionScheduler"
import "FlowVaultsScheduler"
import "FlowVaultsAutoBalancers"
import "DeFiActions"

/// Schedules an autonomous rebalancing transaction for a specific Tide.
///
/// This transaction allows users to schedule periodic or one-time rebalancing operations
/// for their Tides using Flow's native transaction scheduler. The scheduled transaction
/// will automatically rebalance the Tide's AutoBalancer at the specified time(s).
///
/// Note: This transaction must be authorized by the account that owns the AutoBalancer
/// (typically the FlowVaults contract account).
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
/// Example usage:
/// - One-time rebalancing tomorrow: timestamp = now + 86400, isRecurring = false
/// - Daily rebalancing: timestamp = now + 86400, isRecurring = true, recurringInterval = 86400
/// - Hourly rebalancing: timestamp = now + 3600, isRecurring = true, recurringInterval = 3600
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
    let handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
    let wrapperPath: StoragePath
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

        // Get the AutoBalancer storage path
        let autoBalancerPath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: tideID, storage: true) as! StoragePath
        
        // Issue a capability to the AutoBalancer (which implements TransactionHandler)
        // The signer must be the account that owns the AutoBalancer (FlowVaults contract account)
        self.handlerCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(autoBalancerPath)
        
        // Create or reuse a wrapper handler that will emit a FlowVaultsScheduler.RebalancingExecuted event
        self.wrapperPath = FlowVaultsScheduler.deriveRebalancingHandlerPath(tideID: tideID)
        if signer.storage.borrow<&FlowVaultsScheduler.RebalancingHandler>(from: self.wrapperPath) == nil {
            let wrapper <- FlowVaultsScheduler.createRebalancingHandler(
                target: self.handlerCap,
                tideID: tideID
            )
            signer.storage.save(<-wrapper, to: self.wrapperPath)
        }
        self.wrapperCap = signer.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(self.wrapperPath)

        // Verify the AutoBalancer exists
        assert(
            signer.storage.type(at: autoBalancerPath) == Type<@DeFiActions.AutoBalancer>(),
            message: "No AutoBalancer found at \(autoBalancerPath)"
        )

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

