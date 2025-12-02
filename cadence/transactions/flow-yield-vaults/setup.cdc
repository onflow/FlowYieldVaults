import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowYieldVaults"

/// Configures a FlowYieldVaults.YieldVaultManager at the canonical path. If one is already configured, the transaction no-ops
///
transaction {
    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowYieldVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        let betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

        if signer.storage.type(at: FlowYieldVaults.YieldVaultManagerStoragePath) == Type<@FlowYieldVaults.YieldVaultManager>() {
            return // early return if YieldVaultManager is found
        }

        // configure the YieldVaultManager
        signer.storage.save(<-FlowYieldVaults.createYieldVaultManager(betaRef: betaRef), to: FlowYieldVaults.YieldVaultManagerStoragePath)
        let cap = signer.capabilities.storage.issue<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerStoragePath)
        signer.capabilities.publish(cap, at: FlowYieldVaults.YieldVaultManagerPublicPath)
        // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
        signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerStoragePath)

        // confirm setup of YieldVaultManager at canonical path
        let storedType = signer.storage.type(at: FlowYieldVaults.YieldVaultManagerStoragePath) ?? Type<Never>()
        if storedType != Type<@FlowYieldVaults.YieldVaultManager>() {
            panic("Setup was unsuccessful - Expected YieldVaultManager at \(FlowYieldVaults.YieldVaultManagerStoragePath) but found \(storedType.identifier)")
        }
    }
}
