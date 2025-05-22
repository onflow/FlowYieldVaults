import "FungibleToken"

import "YieldToken"

/// MOCK TRANSACTION - DO NOT USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Mints the given amount of YieldToken tokens to the named recipient, reverting if they do not have a Vault configured
///
/// @param recipient: The Flow address to receive the minted tokens
/// @param amount: The amount of YieldToken tokens to mint
///
transaction(recipient: Address, amount: UFix64) {

    let minter: &YieldToken.Minter
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.minter = signer.storage.borrow<&YieldToken.Minter>(from: YieldToken.AdminStoragePath)
            ?? panic("Could not find YieldToken Minter at \(YieldToken.AdminStoragePath)")
        self.receiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(YieldToken.ReceiverPublicPath)
            ?? panic("Could not find FungibleToken Receiver in \(recipient) at path \(YieldToken.ReceiverPublicPath)")
    }

    execute {
        self.receiver.deposit(
            from: <-self.minter.mintTokens(amount: amount)
        )
    }
}
