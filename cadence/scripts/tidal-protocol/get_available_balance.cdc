import "TidalProtocol"

access(all)
fun main(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@TidalProtocol.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find a configured TidalProtocol Pool in account \(protocolAddress) at path \(TidalProtocol.PoolPublicPath)")

    return pool.availableBalance(pid: pid, type: vaultType, pullFromTopUpSource: pullFromTopUpSource)
}
