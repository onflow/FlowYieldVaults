import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaults"

/// Configures a FlowVaults.TideManager at the canonical path. If one is already configured, the transaction no-ops
///
transaction {
    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: FlowVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        let betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

        if signer.storage.type(at: FlowVaults.TideManagerStoragePath) == Type<@FlowVaults.TideManager>() {
            return // early return if TideManager is found
        }

        // configure the TideManager
        signer.storage.save(<-FlowVaults.createTideManager(betaRef: betaRef), to: FlowVaults.TideManagerStoragePath)
        let cap = signer.capabilities.storage.issue<&FlowVaults.TideManager>(FlowVaults.TideManagerStoragePath)
        signer.capabilities.publish(cap, at: FlowVaults.TideManagerPublicPath)
        // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
        signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>(FlowVaults.TideManagerStoragePath)

        // confirm setup of TideManager at canonical path
        let storedType = signer.storage.type(at: FlowVaults.TideManagerStoragePath) ?? Type<Never>()
        if storedType != Type<@FlowVaults.TideManager>() {
            panic("Setup was unsuccessful - Expected TideManager at \(FlowVaults.TideManagerStoragePath) but found \(storedType.identifier)")
        }
    }
}
