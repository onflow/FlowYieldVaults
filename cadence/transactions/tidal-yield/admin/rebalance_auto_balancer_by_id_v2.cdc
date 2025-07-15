import "DFB"
import "DFBv2"
import "TidalYieldAutoBalancersV2"

/// Calls on the AutoBalancerV2 to rebalance using high-precision UInt256 calculations.
/// If force is `true`, rebalancing should occur regardless of the lower & upper thresholds configured.
/// Otherwise, rebalancing will only occur if the value of deposits is above or below the relative thresholds and
/// a rebalance Sink or Source is set.
///
/// @param id: The Tide ID for which the AutoBalancerV2 is associated
/// @param force: Whether or not to force rebalancing, bypassing its thresholds for automatic rebalancing
///
transaction(id: UInt64, force: Bool) {
    // the AutoBalancerV2 that will be rebalanced
    let autoBalancer: auth(DFB.Auto) &DFBv2.AutoBalancerV2
    
    prepare(signer: auth(BorrowValue) &Account) {
        // derive the path and borrow an authorized reference to the AutoBalancerV2
        let storagePath = TidalYieldAutoBalancersV2.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        self.autoBalancer = signer.storage.borrow<auth(DFB.Auto) &DFBv2.AutoBalancerV2>(from: storagePath)
            ?? panic("Could not borrow reference to AutoBalancerV2 id \(id) at path \(storagePath)")
    }

    execute {
        self.autoBalancer.rebalance(force: force)
    }
} 