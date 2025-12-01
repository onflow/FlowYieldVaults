import "FlowCreditMarket"

/// Returns the Pool's reserve balance for a given Vault type
///
/// @param vaultIdentifier: The Type identifier (e.g. vault.getType().identifier) of the related token vault
///
access(all)
fun main(vaultIdentifier: String): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowCreditMarket.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find a configured FlowCreditMarket Pool in account \(protocolAddress) at path \(FlowCreditMarket.PoolPublicPath)")

    return pool.reserveBalance(type: vaultType)
}
