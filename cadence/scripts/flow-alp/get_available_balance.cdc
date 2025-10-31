import "FlowALP"

access(all)
fun main(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowALP.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?? panic("Could not find a configured FlowALP Pool in account \(protocolAddress) at path \(FlowALP.PoolPublicPath)")

    return pool.availableBalance(pid: pid, type: vaultType, pullFromTopUpSource: pullFromTopUpSource)
}
