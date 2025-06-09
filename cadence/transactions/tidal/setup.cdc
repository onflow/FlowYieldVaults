import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "TidalYield"

/// Configures a TidalYield.TideManager at the canonical path. If one is already configured, the transaction no-ops
///
transaction {
    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        if signer.storage.type(at: TidalYield.TideManagerStoragePath) == Type<@TidalYield.TideManager>() {
            return // early return if TideManager is found
        }

        // configure the TideManager
        signer.storage.save(<-TidalYield.createTideManager(), to: TidalYield.TideManagerStoragePath)
        let cap = signer.capabilities.storage.issue<&TidalYield.TideManager>(TidalYield.TideManagerStoragePath)
        signer.capabilities.publish(cap, at: TidalYield.TideManagerPublicPath)
        // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
        signer.capabilities.storage.issue<auth(TidalYield.Owner) &TidalYield.TideManager>(TidalYield.TideManagerStoragePath)

        // confirm setup of TideManager at canonical path
        let storedType = signer.storage.type(at: TidalYield.TideManagerStoragePath) ?? Type<Never>()
        if storedType != Type<@TidalYield.TideManager>() {
            panic("Setup was unsuccessful - Expected TideManager at \(TidalYield.TideManagerStoragePath) but found \(storedType.identifier)")
        }
    }
}
