import "FlowVaultsScheduler"
import "FlowVaultsSchedulerRegistry"
import "FlowTransactionScheduler"
import "FlowToken"
import "FungibleToken"

/// Schedules the global Supervisor for recurring execution.
/// Configurable via arguments; sensible defaults if omitted.
///
/// - timestamp: first run time (now + delta)
/// - priorityRaw: 0=High,1=Medium,2=Low
/// - executionEffort: typical 800
/// - feeAmount: FLOW to cover scheduling fee
/// - recurringInterval: seconds between runs (e.g., 60.0)
/// - childRecurring: whether per-tide jobs should be recurring (true by default)
/// - childInterval: per-tide recurring interval (default 300.0)
/// - forceChild: pass force flag to per-tide jobs (default false)
transaction(
    timestamp: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    feeAmount: UFix64,
    recurringInterval: UFix64,
    childRecurring: Bool,
    childInterval: UFix64,
    forceChild: Bool
) {
    let payment: @FlowToken.Vault
    let handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        // Obtain the global Supervisor capability from the registry. This is
        // configured by calling FlowVaultsScheduler.ensureSupervisorConfigured()
        // (typically via the setup_supervisor.cdc transaction).
        self.handlerCap = FlowVaultsSchedulerRegistry.getSupervisorCap()
            ?? panic("Supervisor not configured")

        let vaultRef = signer.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow FlowToken Vault")
        self.payment <- vaultRef.withdraw(amount: feeAmount) as! @FlowToken.Vault
    }

    execute {
        let prio: FlowTransactionScheduler.Priority =
            priorityRaw == 0 ? FlowTransactionScheduler.Priority.High :
            (priorityRaw == 1 ? FlowTransactionScheduler.Priority.Medium : FlowTransactionScheduler.Priority.Low)

        let cfg: {String: AnyStruct} = {
            "priority": priorityRaw,
            "executionEffort": executionEffort,
            "lookaheadSecs": 5.0,
            "childRecurring": childRecurring,
            "childInterval": childInterval,
            "force": forceChild,
            "recurringInterval": recurringInterval
        }

        let _scheduled <- FlowTransactionScheduler.schedule(
            handlerCap: self.handlerCap,
            data: cfg,
            timestamp: timestamp,
            priority: prio,
            executionEffort: executionEffort,
            fees: <-self.payment
        )
        destroy _scheduled
    }
}


