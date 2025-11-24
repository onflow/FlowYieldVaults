import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaultsClosedBeta"
import "FlowVaults"

/// Opens a new YieldVault in the FlowVaults platform, funding the YieldVault with the specified Vault and amount
///
/// @param strategyIdentifier: The Strategy's Type identifier. Must be a Strategy Type that is currently supported by
///     FlowVaults. See `FlowVaults.getSupportedStrategies()` to get those currently supported.
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
/// @param amount: The amount to deposit into the new YieldVault
///
transaction(strategyIdentifier: String, vaultIdentifier: String, amount: UFix64) {
    let manager: &FlowVaults.YieldVaultManager
    let strategy: Type
    let depositVault: @{FungibleToken.Vault}
    let betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability, CopyValue) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: FlowVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        self.betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

        // create the Strategy Type to compose which the YieldVault should manage
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

        // withdraw the amount to deposit into the new YieldVault
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Signer does not have a vault of type \(vaultIdentifier) at path \(vaultData.storagePath) from which to source funds")
        self.depositVault <- sourceVault.withdraw(amount: amount)

        // configure the YieldVaultManager if needed
        if signer.storage.type(at: FlowVaults.YieldVaultManagerStoragePath) == nil {
            signer.storage.save(<-FlowVaults.createYieldVaultManager(betaRef: self.betaRef), to: FlowVaults.YieldVaultManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&FlowVaults.YieldVaultManager>(FlowVaults.YieldVaultManagerStoragePath)
            signer.capabilities.publish(cap, at: FlowVaults.YieldVaultManagerPublicPath)
            // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
            signer.capabilities.storage.issue<&FlowVaults.YieldVaultManager>(
                    FlowVaults.YieldVaultManagerStoragePath
                )
        }
        self.manager = signer.storage.borrow<&FlowVaults.YieldVaultManager>(from: FlowVaults.YieldVaultManagerStoragePath)
            ?? panic("Signer does not have a YieldVaultManager stored at path \(FlowVaults.YieldVaultManagerStoragePath) - configure and retry")
    }

    execute {
        self.manager.createYieldVault(betaRef: self.betaRef, strategyType: self.strategy, withVault: <-self.depositVault)
    }
}
