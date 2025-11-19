import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaultsClosedBeta"
import "FlowVaults"
import "FlowVaultsScheduler"

/// Opens a new Tide in the FlowVaults platform, funding the Tide with the specified Vault and amount
///
/// @param strategyIdentifier: The Strategy's Type identifier. Must be a Strategy Type that is currently supported by
///     FlowVaults. See `FlowVaults.getSupportedStrategies()` to get those currently supported.
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
/// @param amount: The amount to deposit into the new Tide
///
transaction(strategyIdentifier: String, vaultIdentifier: String, amount: UFix64) {
    let manager: &FlowVaults.TideManager
    let strategy: Type
    let depositVault: @{FungibleToken.Vault}
    let betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability, CopyValue) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: FlowVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        self.betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

        // create the Strategy Type to compose which the Tide should manage
        self.strategy = CompositeType(strategyIdentifier)
            ?? panic("Invalid strategyIdentifier \(strategyIdentifier) - ensure the provided strategyIdentifier corresponds to a valid Strategy Type")

        // get the data for where the vault type is canoncially stored
        let vaultType = CompositeType(vaultIdentifier)
            ?? panic("Vault identifier \(vaultIdentifier) is not associated with a valid Type")
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Vault type \(vaultIdentifier) is not defined by a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for vault type \(vaultIdentifier)")

        // withdraw the amount to deposit into the new Tide
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Signer does not have a vault of type \(vaultIdentifier) at path \(vaultData.storagePath) from which to source funds")
        self.depositVault <- sourceVault.withdraw(amount: amount)

        // configure the TideManager if needed
        if signer.storage.type(at: FlowVaults.TideManagerStoragePath) == nil {
            signer.storage.save(<-FlowVaults.createTideManager(betaRef: self.betaRef), to: FlowVaults.TideManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&FlowVaults.TideManager>(FlowVaults.TideManagerStoragePath)
            signer.capabilities.publish(cap, at: FlowVaults.TideManagerPublicPath)
            // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
            signer.capabilities.storage.issue<&FlowVaults.TideManager>(
                    FlowVaults.TideManagerStoragePath
                )
        }
        self.manager = signer.storage.borrow<&FlowVaults.TideManager>(from: FlowVaults.TideManagerStoragePath)
            ?? panic("Signer does not have a TideManager stored at path \(FlowVaults.TideManagerStoragePath) - configure and retry")
    }

    execute {
        let newID = self.manager.createTide(betaRef: self.betaRef, strategyType: self.strategy, withVault: <-self.depositVault)
        // Auto-register the new Tide with the scheduler so the first rebalance can be seeded without extra steps
        FlowVaultsScheduler.registerTide(tideID: newID)
    }
}
