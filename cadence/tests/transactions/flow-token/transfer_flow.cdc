import "FungibleToken"
import "FlowToken"

transaction(recipient: Address, amount: UFix64) {

    let providerVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.providerVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                from: /storage/flowTokenVault
            )!
        self.receiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver reference")
    }

    execute {
        self.receiver.deposit(
            from: <-self.providerVault.withdraw(
                amount: amount
            )
        )
    }
}
