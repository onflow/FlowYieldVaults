import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

/// Sets up a FungibleToken vault in the signer's storage if not already present,
/// publishing the standard receiver and metadata capabilities.
/// Works with any FT that implements FungibleTokenMetadataViews (including EVMVMBridgedTokens).
///
/// @param contractAddress  Address of the token contract (e.g. 0x1e4aa0b87d10b141)
/// @param contractName     Name of the token contract

transaction(contractAddress: Address, contractName: String) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let viewResolver = getAccount(contractAddress).contracts.borrow<&{ViewResolver}>(name: contractName)
            ?? panic("Cannot borrow ViewResolver for ".concat(contractName))

        let vaultData = viewResolver.resolveContractView(
            resourceType: nil,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Cannot resolve FTVaultData for ".concat(contractName))

        if signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath) != nil {
            return // already set up
        }

        signer.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
        signer.capabilities.unpublish(vaultData.receiverPath)
        signer.capabilities.unpublish(vaultData.metadataPath)
        let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
        let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
        signer.capabilities.publish(receiverCap, at: vaultData.receiverPath)
        signer.capabilities.publish(metadataCap, at: vaultData.metadataPath)
    }
}
