import "FungibleToken"
import "FlowToken"
import "MOET"
import "YieldToken"

transaction(swapPairTemplateHex: String) {
    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability, AddContract) &Account) {
        // Create a new vault and save it to signer's storage at the vault's default storage path
        if signer.storage.borrow<&YieldToken.Vault>(from: YieldToken.VaultStoragePath) == nil {
            signer.storage.save(<-YieldToken.createEmptyVault(vaultType: Type<@YieldToken.Vault>()), to: YieldToken.VaultStoragePath)
        }
        if signer.storage.borrow<&MOET.Vault>(from: MOET.VaultStoragePath) == nil {
            signer.storage.save(<-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()), to: MOET.VaultStoragePath)
        }
        // Issue a public Vault capability and publish it to the vault's default public path
        signer.capabilities.unpublish(YieldToken.ReceiverPublicPath)
        signer.capabilities.unpublish(MOET.ReceiverPublicPath)
        let moetReceiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(MOET.VaultStoragePath)
        signer.capabilities.publish(moetReceiverCap, at: MOET.ReceiverPublicPath)

        let yieldTokenReceiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(YieldToken.VaultStoragePath)
        signer.capabilities.publish(yieldTokenReceiverCap, at: YieldToken.ReceiverPublicPath)

        signer.contracts.add(
            name: "SwapPair",
            code: swapPairTemplateHex.decodeHex(),
            token0Vault: MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()),
            token1Vault: YieldToken.createEmptyVault(vaultType: Type<@YieldToken.Vault>()),
            stableMode: false
        )
    }
}

