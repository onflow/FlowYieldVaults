import "FlowYieldVaults"

/// Returns the YieldVaultBalance view for the yieldVault with the given ID at the provided address or nil if either the
/// address does not have a YieldVaultManager stored, the YieldVault is not available, or the view cannot be resolved.
///
/// @param address: The address of the account to look for the YieldVault
/// @param id: The ID of the YieldVault to query
///
access(all)
fun main(address: Address, id: UInt64): FlowYieldVaults.YieldVaultBalance? {
    if let manager = getAccount(address)
        .capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerPublicPath)
    {
        if let yieldVault = manager.borrowYieldVault(id: id) {
            if !yieldVault.getViews().contains(Type<FlowYieldVaults.YieldVaultBalance>()) {
                return nil
            }
            return yieldVault.resolveView(Type<FlowYieldVaults.YieldVaultBalance>()) as? FlowYieldVaults.YieldVaultBalance
        }
    }
    return nil
}
