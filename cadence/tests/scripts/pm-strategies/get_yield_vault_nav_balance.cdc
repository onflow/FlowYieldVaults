import "FlowYieldVaults"

access(all)
fun main(address: Address, id: UInt64): UFix64? {
    let yieldVault = getAccount(address).capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerPublicPath)
        ?.borrowYieldVault(id: id)
        ?? nil
    return yieldVault?.getNAVBalance() ?? nil
}
