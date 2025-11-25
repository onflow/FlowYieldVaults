import "FungibleToken"

import "MOET"

/// Mints MOET using the Minter stored in the signer's account and deposits to the recipients MOET Vault. If the
/// recipient's MOET Vault is not configured with a public Capability or the signer does not have a MOET Minter
/// stored, the transaction will revert.
///
/// @param to: The recipient's Flow address
/// @param amount: How many MOET tokens to mint to the recipient's account
///
transaction(to: Address, amount: UFix64) {

    let receiver: &{FungibleToken.Vault}
    let minter: &MOET.Minter

    prepare(signer: auth(BorrowValue) &Account) {
        self.minter = signer.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to MOET Minter from signer's account at path \(MOET.AdminStoragePath)")
        self.receiver = getAccount(to).capabilities.borrow<&{FungibleToken.Vault}>(MOET.VaultPublicPath)
            ?? panic("Could not borrow reference to MOET Vault from recipient's account at path \(MOET.VaultPublicPath)")
    }

    execute {
        self.receiver.deposit(
            from: <-self.minter.mintTokens(amount: amount)
        )
    }
}
