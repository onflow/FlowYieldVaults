import "FungibleToken"
import "FlowEVMBridgeConfig"
import "EVM"
import "ViewResolver"
import "FungibleTokenMetadataViews"

/// Creates a vault for a bridged EVM token at the correct storage path
/// This is required before you can receive tokens bridged from EVM to Cadence
///
/// @param evmAddressHex: The EVM address of the token (with 0x prefix)
///
transaction(evmAddressHex: String) {
    prepare(signer: auth(Storage, Capabilities, UnpublishCapability) &Account) {
        let evmAddr = EVM.addressFromString(evmAddressHex)
        let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: evmAddr)
            ?? panic("No vault type associated with ".concat(evmAddressHex))
        
        // Get the contract address and name from the type identifier
        let tokenContractAddress = vaultType.identifier.slice(from: 2, upTo: 18)
        let tokenContractName = vaultType.identifier.slice(
            from: vaultType.identifier.length - (vaultType.identifier.split(separator: ".")[2]!.length),
            upTo: vaultType.identifier.length
        )
        
        // Borrow the ViewResolver to get vault configuration
        let viewResolver = getAccount(Address.fromString("0x".concat(tokenContractAddress))!)
            .contracts.borrow<&{ViewResolver}>(name: tokenContractName)
            ?? panic("Could not borrow ViewResolver from contract")
        
        let vaultData = viewResolver.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData view")
        
        // Check if vault already exists
        if signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath) == nil {
            // Create and save vault
            signer.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
            
            // Unpublish existing capabilities if any
            signer.capabilities.unpublish(vaultData.receiverPath)
            signer.capabilities.unpublish(vaultData.metadataPath)
            
            // Create and publish capabilities
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            
            signer.capabilities.publish(receiverCap, at: vaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: vaultData.metadataPath)
            
            log("✅ Created vault at ".concat(vaultData.storagePath.toString()))
        } else {
            log("ℹ️  Vault already exists at ".concat(vaultData.storagePath.toString()))
        }
    }
}

