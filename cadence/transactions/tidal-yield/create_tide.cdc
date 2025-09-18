import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "TidalYieldClosedBeta"
import "TidalYield"

/// Opens a new Tide in the Tidal platform, funding the Tide with the specified Vault and amount
///
/// @param strategyIdentifier: The Strategy's Type identifier. Must be a Strategy Type that is currently supported by
///     TidalYield. See `TidalYield.getSupportedStrategies()` to get those currently supported.
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
/// @param amount: The amount to deposit into the new Tide
///
transaction(strategyIdentifier: String, vaultIdentifier: String, amount: UFix64) {
    let manager: &TidalYield.TideManager
    let strategy: Type
    let depositVault: @{FungibleToken.Vault}
    let betaRef: &{TidalYieldClosedBeta.IBeta}

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability, CopyValue) &Account) {
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
        if signer.storage.type(at: TidalYield.TideManagerStoragePath) == nil {
            signer.storage.save(<-TidalYield.createTideManager(), to: TidalYield.TideManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&TidalYield.TideManager>(TidalYield.TideManagerStoragePath)
            signer.capabilities.publish(cap, at: TidalYield.TideManagerPublicPath)
            // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
            signer.capabilities.storage.issue<&TidalYield.TideManager>(
                    TidalYield.TideManagerStoragePath
                )
        }
        self.manager = signer.storage.borrow<&TidalYield.TideManager>(from: TidalYield.TideManagerStoragePath)
            ?? panic("Signer does not have a TideManager stored at path \(TidalYield.TideManagerStoragePath) - configure and retry")
        let betaCap = signer.storage.copy<Capability<&{TidalYieldClosedBeta.IBeta}>>(from: TidalYieldClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer doesn not have a BetaBadge stored at path \(TidalYieldClosedBeta.UserBetaCapStoragePath) - configure and retry")

        self.betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")

    }

    execute {
        self.manager.createTide(betaRef: self.betaRef, strategyType: self.strategy, withVault: <-self.depositVault)
    }
}
