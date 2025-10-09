import "FungibleToken"
import "FlowToken"
import "MOET"
import "YieldToken"

transaction(recipient: Address, amount: UFix64) {

    let providerFlowVault: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let providerMOETVault: auth(FungibleToken.Withdraw) &MOET.Vault
    let providerYieldTokenVault: auth(FungibleToken.Withdraw) &YieldToken.Vault
    let receiverFlow: &{FungibleToken.Receiver}
    let receiverMOET: &{FungibleToken.Receiver}
    let receiverYieldToken: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.providerFlowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                from: /storage/flowTokenVault
            )!
        self.providerMOETVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(
                from: MOET.VaultStoragePath
            )!
        self.providerYieldTokenVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &YieldToken.Vault>(
                from: YieldToken.VaultStoragePath
            )!
        self.receiverFlow = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver FLOW reference")
        self.receiverMOET = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(MOET.ReceiverPublicPath)
            ?? panic("Could not borrow receiver FLOW reference")
        self.receiverYieldToken = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(YieldToken.ReceiverPublicPath)
            ?? panic("Could not borrow receiver FLOW reference")
    }

    execute {
        self.receiverFlow.deposit(
            from: <-self.providerFlowVault.withdraw(
                amount: amount
            )
        )
        self.receiverMOET.deposit(
            from: <-self.providerMOETVault.withdraw(
                amount: amount
            )
        )
        self.receiverYieldToken.deposit(
            from: <-self.providerYieldTokenVault.withdraw(
                amount: amount
            )
        )
    }
}
