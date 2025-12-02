import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaults"

/// Configures a FlowVaults.YieldVaultManager at the canonical path. If one is already configured, the transaction no-ops
///
transaction {
    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: FlowVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        let betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

        if signer.storage.type(at: FlowVaults.YieldVaultManagerStoragePath) == Type<@FlowVaults.YieldVaultManager>() {
            return // early return if YieldVaultManager is found
        }

        // configure the YieldVaultManager
        signer.storage.save(<-FlowVaults.createYieldVaultManager(betaRef: betaRef), to: FlowVaults.YieldVaultManagerStoragePath)
        let cap = signer.capabilities.storage.issue<&FlowVaults.YieldVaultManager>(FlowVaults.YieldVaultManagerStoragePath)
        signer.capabilities.publish(cap, at: FlowVaults.YieldVaultManagerPublicPath)
        // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
        signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowVaults.YieldVaultManager>(FlowVaults.YieldVaultManagerStoragePath)

        // confirm setup of YieldVaultManager at canonical path
        let storedType = signer.storage.type(at: FlowVaults.YieldVaultManagerStoragePath) ?? Type<Never>()
        if storedType != Type<@FlowVaults.YieldVaultManager>() {
            panic("Setup was unsuccessful - Expected YieldVaultManager at \(FlowVaults.YieldVaultManagerStoragePath) but found \(storedType.identifier)")
        }
    }
}
