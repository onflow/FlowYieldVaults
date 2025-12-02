import "FlowToken"
import "FungibleToken"

/// Returns the FLOW token balance for an account
///
/// @param address: The account address to check
/// @return UFix64: The FLOW balance
///
access(all) fun main(address: Address): UFix64 {
    let account = getAccount(address)
    let vaultRef = account.capabilities.borrow<&{FungibleToken.Balance}>(/public/flowTokenBalance)
    return vaultRef?.balance ?? 0.0
}

