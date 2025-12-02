import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaults"

/// Withdraws the full balance from an existing YieldVault stored in the signer's YieldVaultManager and closes the YieldVault. If the
/// signer does not yet have a Vault of the withdrawn Type, one is configured.
///
/// @param id: The YieldVault.id() of the YieldVault from which the full balance will be withdrawn
///
transaction(id: UInt64) {
    let manager: auth(FungibleToken.Withdraw) &FlowVaults.YieldVaultManager
    let receiver: &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, StorageCapabilities, PublishCapability) &Account) {
        // reference the signer's YieldVaultManager & underlying YieldVault
        self.manager = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowVaults.YieldVaultManager>(from: FlowVaults.YieldVaultManagerStoragePath)
            ?? panic("Signer does not have a YieldVaultManager stored at path \(FlowVaults.YieldVaultManagerStoragePath) - configure and retry")
        let yieldVault = self.manager.borrowYieldVault(id: id) ?? panic("YieldVault with ID \(id) was not found")
        
        // get the data for where the vault type is canoncially stored
        let vaultType = yieldVault.getSupportedVaultTypes().keys[0]
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
            from: <-self.manager.closeYieldVault(id)
        )
    }
}
