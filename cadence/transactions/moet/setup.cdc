import "FungibleToken"
import "ViewResolver"

import "USDA"

/// Configures a USDA Vault if one is not found, ensuring proper configuration in storage
///
transaction {
    prepare(signer: auth(SaveValue, BorrowValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // configure if nothing is found at canonical path
        if signer.storage.type(at: USDA.VaultStoragePath) == nil {
            // save the new vault
            signer.storage.save(<-USDA.createEmptyVault(vaultType: Type<@USDA.Vault>()), to: USDA.VaultStoragePath)
            // publish a public capability on the Vault
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(USDA.VaultStoragePath)
            signer.capabilities.unpublish(USDA.ReceiverPublicPath)
            signer.capabilities.publish(cap, at: USDA.ReceiverPublicPath)
            // issue an authorized capability to initialize a CapabilityController on the account, but do not publish
            signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(USDA.VaultStoragePath)
        }
        // ensure proper configuration
        if signer.storage.type(at: USDA.VaultStoragePath) != Type<@USDA.Vault>(){
            panic("Could not configure USDA Vault at \(USDA.VaultStoragePath) - check for collision and try again")
        }
    }
}
