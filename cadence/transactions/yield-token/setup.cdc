import "FungibleToken"
import "ViewResolver"

import "YieldToken"

/// Configures a YieldToken Vault if one is not found, ensuring proper configuration in storage
///
transaction {
    prepare(signer: auth(SaveValue, BorrowValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // configure if nothing is found at canonical path
        if signer.storage.type(at: YieldToken.VaultStoragePath) == nil {
            // save the new vault
            signer.storage.save(<-YieldToken.createEmptyVault(vaultType: Type<@YieldToken.Vault>()), to: YieldToken.VaultStoragePath)
            // publish a public capability on the Vault
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(YieldToken.VaultStoragePath)
            signer.capabilities.unpublish(YieldToken.ReceiverPublicPath)
            signer.capabilities.publish(cap, at: YieldToken.ReceiverPublicPath)
            // issue an authorized capability to initialize a CapabilityController on the account, but do not publish
            signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(YieldToken.VaultStoragePath)
        }
        // ensure proper configuration
        if signer.storage.type(at: YieldToken.VaultStoragePath) != Type<@YieldToken.Vault>(){
            panic("Could not configure YieldToken Vault at \(YieldToken.VaultStoragePath) - check for collision and try again")
        }
    }
}
