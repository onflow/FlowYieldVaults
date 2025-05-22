import "FungibleToken"

import "USDA"

/// MOCK TRANSACTION - DO NOT USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Mints the given amount of USDA tokens to the named recipient, reverting if they do not have a Vault configured
///
/// @param recipient: The Flow address to receive the minted tokens
/// @param amount: The amount of USDA tokens to mint
///
transaction(recipient: Address, amount: UFix64) {

    let minter: &USDA.Minter
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.minter = signer.storage.borrow<&USDA.Minter>(from: USDA.AdminStoragePath)
            ?? panic("Could not find USDA Minter at \(USDA.AdminStoragePath)")
        self.receiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(USDA.ReceiverPublicPath)
            ?? panic("Could not find FungibleToken Receiver in \(recipient) at path \(USDA.ReceiverPublicPath)")
    }

    execute {
        self.receiver.deposit(
            from: <-self.minter.mintTokens(amount: amount)
        )
    }
}
