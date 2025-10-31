import "FlowALP"

/// Returns the Pool's reserve balance for a given Vault type
///
/// @param vaultIdentifier: The Type identifier (e.g. vault.getType().identifier) of the related token vault
///
access(all)
fun main(vaultIdentifier: String): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowALP.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?? panic("Could not find a configured FlowALP Pool in account \(protocolAddress) at path \(FlowALP.PoolPublicPath)")

    return pool.reserveBalance(type: vaultType)
}
