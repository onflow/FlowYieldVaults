import "FlowStorageFees"
import "FungibleToken"
import "FlowToken"

import "EVM"

// Transfers $FLOW from the signer's account to the recipient's address, determining the target VM based on the format
// of the recipient's hex address. Note that the sender's funds are sourced by default from the target VM, pulling any
// difference from the alternate VM if available. e.g. Transfers to Flow addresses will first attempt to withdraw from
// the signer's Flow vault, pulling any remaining funds from the signer's EVM account if available. Transfers to EVM
// addresses will first attempt to withdraw from the signer's EVM account, pulling any remaining funds from the signer's
// Flow vault if available. If the signer's balance across both VMs is insufficient, the transaction will revert.
///
/// @param addressString: The recipient's address in hex format - this should be either an EVM address or a Flow address
/// @param amount: The amount of $FLOW to transfer as a UFix64 value
///
transaction(addressString: String, amount: UFix64) {

    let sentVault: @FlowToken.Vault
    let evmRecipient: EVM.EVMAddress?

    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Reference signer's COA if one exists
        let coa = signer.storage.borrow<auth(EVM.Withdraw) &EVM.CadenceOwnedAccount>(from: /storage/evm)

        // Reference signer's FlowToken Vault
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
        ?? panic("Could not borrow signer's FlowToken.Vault")
        // Ensure we don't withdraw more than required for storage
        let cadenceBalance = FlowStorageFees.defaultTokenAvailableBalance(signer.address)

        // Define optional recipients for both VMs
        self.evmRecipient = EVM.addressFromString(addressString)
        // Validate exactly one target address is assigned
        if self.evmRecipient == nil {
            panic("Malformed recipient address - not assignable as either Cadence or EVM address")
        }

        // Create empty FLOW vault to capture funds
        self.sentVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())

        // Check signer's balance can cover the amount
        if coa != nil {
            // Determine the amount to withdraw from the signer's EVM account
            let balance = coa!.balance()
            let withdrawAmount = amount < balance.inFLOW() ? amount : balance.inFLOW()
            balance.setFLOW(flow: withdrawAmount)

            // Withdraw funds from EVM to the sentVault
            self.sentVault.deposit(from: <-coa!.withdraw(balance: balance))
        }
        if amount > self.sentVault.balance {
            // Insufficient amount withdrawn from EVM, check signer's Flow balance
            let difference = amount - self.sentVault.balance
            if difference > cadenceBalance {
                panic("Insufficient balance across Flow and EVM accounts")
            }
            // Withdraw from the signer's Cadence Vault and deposit to sentVault
            self.sentVault.deposit(from: <-sourceVault.withdraw(amount: difference))
        }
    }

    pre {
        self.sentVault.balance == amount: "Attempting to send an incorrect amount of $FLOW"
    }

    execute {
        // Otherwise, complete EVM transfer
        self.evmRecipient!.deposit(from: <-self.sentVault)
    }
}
