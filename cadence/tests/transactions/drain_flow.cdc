import "FlowToken"
import "FungibleToken"

/// [TEST ONLY] Drains FLOW from the signer's account
/// This is used to simulate insufficient funds for scheduling fees
///
/// @param amount: The amount of FLOW to drain (burn)
///
transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken Vault")
        
        // Withdraw the amount
        let withdrawn <- vaultRef.withdraw(amount: amount)
        
        // Burn it (effectively draining the account)
        destroy withdrawn
    }
}

