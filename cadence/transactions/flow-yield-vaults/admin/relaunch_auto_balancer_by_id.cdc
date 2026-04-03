import "FungibleToken"
import "FungibleTokenConnectors"
import "DeFiActions"
import "FlowTransactionScheduler"
import "FlowYieldVaultsAutoBalancers"

/// Sets recurring config for a specific AutoBalancer and immediately schedules its next rebalance.
///
/// @param id: The YieldVault/AutoBalancer ID
/// @param interval: The interval at which to rebalance (in seconds)
/// @param priorityRaw: The priority of the rebalance (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The execution effort of the rebalance (1-9999)
/// @param forceRebalance: The force rebalance flag (true=force rebalance, false=normal rebalance)
transaction(
    id: UInt64,
    interval: UInt64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    forceRebalance: Bool
) {
    let autoBalancer: auth(DeFiActions.Identify, DeFiActions.Configure, DeFiActions.Schedule) &DeFiActions.AutoBalancer

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let storagePath = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        self.autoBalancer = signer.storage
            .borrow<auth(DeFiActions.Identify, DeFiActions.Configure, DeFiActions.Schedule) &DeFiActions.AutoBalancer>(from: storagePath)
            ?? panic("Could not borrow AutoBalancer id \(id) at path \(storagePath)")

        let feeCapStoragePath = /storage/strategiesFeeSource
        let fundingVault = signer.storage
            .copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: feeCapStoragePath)
            ?? panic("Could not find funding vault Capability at \(feeCapStoragePath)")

        var txnFunder = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: fundingVault,
            uniqueID: nil
        )

        DeFiActions.alignID(
            toUpdate: &txnFunder as auth(DeFiActions.Extend) &{DeFiActions.IdentifiableStruct},
            with: self.autoBalancer
        )

        let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
            ?? panic("Invalid priority: \(priorityRaw) - must be 0=High, 1=Medium, 2=Low")

        let config = DeFiActions.AutoBalancerRecurringConfig(
            interval: interval,
            priority: priority,
            executionEffort: executionEffort,
            forceRebalance: forceRebalance,
            txnFunder: txnFunder
        )

        self.autoBalancer.setRecurringConfig(config)
    }

    execute {
        if let err = self.autoBalancer.scheduleNextRebalance(whileExecuting: nil) {
            panic("Failed to schedule next rebalance for AutoBalancer \(id): \(err)")
        }
    }
}
