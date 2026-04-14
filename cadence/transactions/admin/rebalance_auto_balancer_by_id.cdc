import "DeFiActions"

import "FlowYieldVaultsAutoBalancers"

/// Calls on the AutoBalancer to rebalance which will result in a rebalancing around the value of deposits. If force is
/// `true`, rebalancing should occur regardless of the lower & upper thresholds configured on the AutoBalancer.
/// Otherwise, rebalancing will only occur if the value of deposits is above or below the relative thresholds and
/// a rebalance Sink or Source is set.
///
/// For more information on DeFiActions AutoBalancers, see the DeFiActions contract.
///
/// @param id: The YieldVault ID for which the AutoBalancer is associated
/// @param force: Whether or not to force rebalancing, bypassing it's thresholds for automatic rebalancing
///
transaction(id: UInt64, force: Bool) {
    // the AutoBalancer that will be rebalanced
    let autoBalancer: auth(DeFiActions.Auto) &DeFiActions.AutoBalancer
    
    prepare(signer: auth(BorrowValue) &Account) {
        // derive the path and borrow an authorized reference to the AutoBalancer
        let storagePath = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        self.autoBalancer = signer.storage.borrow<auth(DeFiActions.Auto) &DeFiActions.AutoBalancer>(from: storagePath)
            ?? panic("Could not borrow reference to AutoBalancer id \(id) at path \(storagePath)")
    }

    execute {
        self.autoBalancer.rebalance(force: force)
    }
}
