import "FungibleToken"

import "MOET"
import "YieldToken"
import "MockDexSwapper"

/// TEST-ONLY: Perform a fixed-ratio swap YIELD -> MOET using MockDexSwapper
transaction(amount: UFix64, priceRatio: UFix64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability, SaveValue, UnpublishCapability) &Account) {
        // Ensure YIELD in-vault and MOET receiver
        if signer.storage.type(at: YieldToken.VaultStoragePath) == nil {
            signer.storage.save(<-YieldToken.createEmptyVault(vaultType: Type<@YieldToken.Vault>()), to: YieldToken.VaultStoragePath)
            let yCap = signer.capabilities.storage.issue<&YieldToken.Vault>(YieldToken.VaultStoragePath)
            signer.capabilities.unpublish(YieldToken.ReceiverPublicPath)
            signer.capabilities.publish(yCap, at: YieldToken.ReceiverPublicPath)
        }
        if signer.storage.type(at: MOET.VaultStoragePath) == nil {
            signer.storage.save(<-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()), to: MOET.VaultStoragePath)
            let mCap = signer.capabilities.storage.issue<&MOET.Vault>(MOET.VaultStoragePath)
            signer.capabilities.unpublish(MOET.VaultPublicPath)
            signer.capabilities.publish(mCap, at: MOET.VaultPublicPath)
        }

        let yWithdraw = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: YieldToken.VaultStoragePath)
            ?? panic("Missing Yield vault")
        let moetReceiver = getAccount(signer.address).capabilities.borrow<&{FungibleToken.Receiver}>(MOET.ReceiverPublicPath)
            ?? panic("Missing MOET receiver")

        // Source cap for MOET withdrawals (out token)
        let moetSource = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)

        let swapper = MockDexSwapper.Swapper(
            inVault: Type<@YieldToken.Vault>(),
            outVault: Type<@MOET.Vault>(),
            vaultSource: moetSource,
            priceRatio: priceRatio,
            uniqueID: nil
        )

        let sent <- yWithdraw.withdraw(amount: amount)
        let received <- swapper.swap(quote: nil, inVault: <-sent)
        moetReceiver.deposit(from: <-received)
    }
}


