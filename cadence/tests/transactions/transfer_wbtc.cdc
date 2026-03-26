import "FungibleToken"

transaction(recipient: Address, amount: UFix64) {

    let providerVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
    let receiver: &{FungibleToken.Receiver}

    let storagePath: StoragePath
    let receiverPath: PublicPath

    prepare(signer: auth(BorrowValue) &Account) {
        self.storagePath = /storage/EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579Vault
        self.receiverPath = /public/EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579Receiver

        self.providerVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
                from: self.storagePath
            ) ?? panic("Could not borrow wBTC vault reference from signer")

        self.receiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(self.receiverPath)
            ?? panic("Could not borrow receiver reference from recipient")
    }

    execute {
        self.receiver.deposit(
            from: <-self.providerVault.withdraw(
                amount: amount
            )
        )
    }
}
