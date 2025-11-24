import "FlowVaults"

/// Retrieves the IDs of YieldVaults configured at the provided address or `nil` if a YieldVaultManager is not stored
///
/// @param address: The address of the Flow account in question
///
/// @return A UInt64 array of all YieldVault IDs stored in the account's YieldVaultManager
///
access(all)
fun main(address: Address): [UInt64]? {
    return getAccount(address).capabilities.borrow<&FlowVaults.YieldVaultManager>(FlowVaults.YieldVaultManagerPublicPath)
        ?.getIDs()
}
