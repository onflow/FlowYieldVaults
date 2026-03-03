// Deposits FLOW from signer's FlowToken vault to the signer's COA (native EVM balance).
// Use before swaps/bridges that need the COA to pay gas or bridge fees.
import "FungibleToken"
import "FlowToken"
import "EVM"

transaction(amount: UFix64) {
    prepare(signer: auth(Storage, BorrowValue) &Account) {
        let coa = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA at /storage/evm")
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("No FlowToken vault")
        let deposit <- flowVault.withdraw(amount: amount) as! @FlowToken.Vault
        coa.deposit(from: <-deposit)
    }
}
