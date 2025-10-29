import "FungibleToken"
import "FlowEVMBridgeConfig"
import "EVM"

/// Creates a vault for a bridged EVM token at the correct storage path
/// This is required before you can receive tokens bridged from EVM to Cadence
///
/// @param evmAddressHex: The EVM address of the token (with 0x prefix)
///
transaction(evmAddressHex: String) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let evmAddr = EVM.addressFromString(evmAddressHex)
        let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: evmAddr)
            ?? panic("No vault type associated with ".concat(evmAddressHex))
        
        // Construct storage path: /storage/EVMVMBridgedToken_<lowercase_address_without_0x>Vault
        let pathIdentifier = "EVMVMBridgedToken_".concat(
            evmAddressHex.slice(from: 2, upTo: evmAddressHex.length).toLower()
        ).concat("Vault")
        
        let storagePath = StoragePath(identifier: pathIdentifier)!
        let publicPath = PublicPath(identifier: pathIdentifier.concat("_balance"))!
        
        // Check if vault already exists
        if signer.storage.type(at: storagePath) == nil {
            // Create and save vault
            let vault <- FlowEVMBridgeConfig.createEmptyVault(type: vaultType)
            signer.storage.save(<-vault, to: storagePath)
            
            // Create public capability for balance checking
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(storagePath)
            signer.capabilities.publish(cap, at: publicPath)
            
            log("✅ Created vault at ".concat(storagePath.toString()))
        } else {
            log("ℹ️  Vault already exists at ".concat(storagePath.toString()))
        }
    }
}

