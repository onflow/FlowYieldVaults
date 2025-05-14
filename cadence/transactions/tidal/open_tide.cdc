import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "Tidal"

/// Opens a new Tide in the Tidal platform, funding the Tide with the specified Vault and amount
///
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
/// @param amount: The amount to deposit into the new Tide
///
transaction(vaultIdentifier: String, amount: UFix64) {
    let manager: &Tidal.TideManager
    let depositVault: @{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
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
        if signer.storage.type(at: Tidal.TideManagerStoragePath) == nil {
            signer.storage.save(<-Tidal.createTideManager(), to: Tidal.TideManagerStoragePath)
            let cap = signer.capabilities.storage.issue<&Tidal.TideManager>(Tidal.TideManagerStoragePath)
            signer.capabilities.publish(cap, at: Tidal.TideManagerPublicPath)
            // issue an authorized capability for later access via Capability controller if needed (e.g. via HybridCustody)
            signer.capabilities.storage.issue<auth(Tidal.Owner) &Tidal.TideManager>(
                    Tidal.TideManagerStoragePath
                )
        }
        self.manager = signer.storage.borrow<&Tidal.TideManager>(from: Tidal.TideManagerStoragePath)
            ?? panic("Signer does not have a TideManager stored at path \(Tidal.TideManagerStoragePath) - configure and retry")
    }

    execute {
        self.manager.createTide(withVault: <-self.depositVault)
    }
}