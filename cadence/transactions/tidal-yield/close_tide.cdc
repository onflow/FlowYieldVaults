import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "Tidal"

/// Withdraws the full balance from an existing Tide stored in the signer's TideManager and closes the Tide. If the
/// signer does not yet have a Vault of the withdrawn Type, one is configured.
///
/// @param id: The Tide.id() of the Tide from which the full balance will be withdrawn
///
transaction(id: UInt64) {
    let manager: auth(FungibleToken.Withdraw) &Tidal.TideManager
    let receiver: &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        // reference the signer's TideManager & underlying Tide
        self.manager = signer.storage.borrow<auth(FungibleToken.Withdraw) &Tidal.TideManager>(from: Tidal.TideManagerStoragePath)
            ?? panic("Signer does not have a TideManager stored at path \(Tidal.TideManagerStoragePath) - configure and retry")
        let tide = self.manager.borrowTide(id: id) ?? panic("Tide with ID \(id) was not found")
        
        // get the data for where the vault type is canoncially stored
        let vaultType = tide.getSupportedVaultTypes().keys[0]
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Vault type \(vaultType.identifier) is not defined by a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for vault type \(vaultType.identifier)")

        // configure a receiving Vault if none exists
        if signer.storage.type(at: vaultData.storagePath) == nil {
            signer.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
            let vaultCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            signer.capabilities.publish(vaultCap, at: vaultData.metadataPath)
            signer.capabilities.publish(vaultCap, at: vaultData.receiverPath)
        }

        // reference the signer's receiver
        self.receiver = signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Signer does not have a vault of type \(vaultType.identifier) at path \(vaultData.storagePath) from which to source funds")
    }

    execute {
        self.receiver.deposit(
            from: <-self.manager.closeTide(id)
        )
    }
}
