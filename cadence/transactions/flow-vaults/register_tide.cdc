import "FlowVaultsScheduler"
import "DeFiActions"
import "FlowVaultsAutoBalancers"

/// Registers a Tide ID for supervision. Must be run by the FlowVaults (tidal) account.
/// Verifies that an AutoBalancer exists for the given tideID.
transaction(tideID: UInt64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue) &Account) {
        let abPath = FlowVaultsAutoBalancers.deriveAutoBalancerPath(id: tideID, storage: true) as! StoragePath
        let exists = signer.storage.type(at: abPath) == Type<@DeFiActions.AutoBalancer>()
        assert(exists, message: "No AutoBalancer found for tideID \(tideID)")
        FlowVaultsScheduler.registerTide(tideID: tideID)
    }
}


