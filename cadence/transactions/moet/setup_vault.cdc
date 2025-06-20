import "FungibleToken"

import "MOET"

/// Creates & stores a MOET Vault in the signer's account, also configuring its public Vault Capability
///
transaction {

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // configure if nothing is found at canonical path
        if signer.storage.type(at: MOET.VaultStoragePath) == nil {
            // save the new vault
            signer.storage.save(<-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()), to: MOET.VaultStoragePath)
            // publish a public capability on the Vault
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(MOET.VaultStoragePath)
            signer.capabilities.unpublish(MOET.VaultPublicPath)
            signer.capabilities.unpublish(MOET.ReceiverPublicPath)
            signer.capabilities.publish(cap, at: MOET.VaultPublicPath)
            signer.capabilities.publish(cap, at: MOET.ReceiverPublicPath)
            // issue an authorized capability to initialize a CapabilityController on the account, but do not publish
            signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)
        }

        // ensure proper configuration
        if signer.storage.type(at: MOET.VaultStoragePath) != Type<@MOET.Vault>(){
            panic("Could not configure MOET Vault at \(MOET.VaultStoragePath) - check for collision and try again")
        }
    }
}
