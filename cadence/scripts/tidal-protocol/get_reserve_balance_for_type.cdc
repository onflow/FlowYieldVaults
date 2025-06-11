import "TidalProtocol"

/// Returns the Pool's reserve balance for a given Vault type
///
/// @param vaultIdentifier: The Type identifier (e.g. vault.getType().identifier) of the related token vault
///
access(all)
fun main(vaultIdentifier: String): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@TidalProtocol.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find a configured TidalProtocol Pool in account \(protocolAddress) at path \(TidalProtocol.PoolPublicPath)")

    return pool.reserveBalance(type: vaultType)
}
