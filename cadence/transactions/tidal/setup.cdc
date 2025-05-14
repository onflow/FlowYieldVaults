import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "Tidal"

/// Configures a Tidal.TideManager at the canonical path. If one is already configured, the transaction no-ops
///
transaction {
    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        if signer.storage.type(at: Tidal.TideManagerStoragePath) == Type<@Tidal.TideManager>() {
            return // early return if TideManager is found
        }

        // configure the TideManager
        signer.storage.save(<-Tidal.createTideManager(), to: Tidal.TideManagerStoragePath)
        let cap = signer.capabilities.storage.issue<&Tidal.TideManager>(Tidal.TideManagerStoragePath)
        signer.capabilities.publish(cap, at: Tidal.TideManagerPublicPath)
        // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
        signer.capabilities.storage.issue<auth(Tidal.Owner) &Tidal.TideManager>(Tidal.TideManagerStoragePath)

        // confirm setup of TideManager at canonical path
        let storedType = signer.storage.type(at: Tidal.TideManagerStoragePath) ?? Type<Never>()
        if storedType != Type<@Tidal.TideManager>() {
            panic("Setup was unsuccessful - Expected TideManager at \(Tidal.TideManagerStoragePath) but found \(storedType.identifier)")
        }
    }
}
