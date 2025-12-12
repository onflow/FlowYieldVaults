import "FungibleToken"
import "FlowToken"
import "FungibleTokenConnectors"
import "DeFiActions"
import "FlowTransactionScheduler"
import "FlowYieldVaultsAutoBalancers"
import "FlowYieldVaultsSchedulerRegistry"

/// Sets the recurring config for all AutoBalancers tied to registered yVaults.
/// NOTE: This transaction is intended for beta-level use only. Iteration in `prepare` will fail with enough yVaults.
///
/// @param interval: The interval at which to rebalance (in seconds)
/// @param priorityRaw: The priority of the rebalance (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The execution effort of the rebalance (1-9999)
/// @param forceRebalance: The force rebalance flag (true=force rebalance, false=normal rebalance)
transaction(
    interval: UInt64,
    priorityRaw: UInt8,
    executionEffort: UInt64,
    forceRebalance: Bool
) {

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let feeCapStoragePath = /storage/strategiesFeeSource
        let fundingVault = signer.storage.copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: feeCapStoragePath)
            ?? panic("Could not find funding vault Capability at \(feeCapStoragePath)")
        let txnFunder = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: fundingVault,
            uniqueID: nil
        )
        let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw)
            ?? panic("Invalid priority: \(priorityRaw) - must be 0=High, 1=Medium, 2=Low")
        for id in FlowYieldVaultsSchedulerRegistry.getPendingYieldVaultIDs() {
            let path = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
            if let ab = signer.storage.borrow<auth(DeFiActions.Identify, DeFiActions.Auto) &DeFiActions.AutoBalancer>(from: path) {
                DeFiActions.alignID(
                    toUpdate: &txnFunder as auth(DeFiActions.Extend) &{DeFiActions.IdentifiableStruct},
                    with: ab
                )
                let config = DeFiActions.AutoBalancerRecurringConfig(
                    interval: interval,
                    priority: priority,
                    executionEffort: executionEffort,
                    forceRebalance: forceRebalance,
                    txnFunder: txnFunder
                )
                ab.setRecurringConfig(config)
            }
        }
    }
}
