import "FlowVaults"

/// Returns the balance of the yieldVault with the given ID at the provided address or nil if either the address does not
/// have a YieldVaultManager stored or the YieldVault is not available. Note this `nil` does not mean a YieldVault with the given ID
/// does not exist, solely that the YieldVault is not stored at the provided address.
///
/// @param address: The address of the account to look for the YieldVault
/// @param id: The ID of the YieldVault to query the balance of
///
/// @return the balance of the YieldVault or `nil` if the YieldVault was not found
///
access(all)
fun main(address: Address, id: UInt64): UFix64? {
    let yieldVault = getAccount(address).capabilities.borrow<&FlowVaults.YieldVaultManager>(FlowVaults.YieldVaultManagerPublicPath)
        ?.borrowYieldVault(id: id)
        ?? nil
    return yieldVault?.getYieldVaultBalance() ?? nil
}
