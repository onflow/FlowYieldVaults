import "FlowCreditMarket"

access(all)
fun main(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowCreditMarket.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find a configured FlowCreditMarket Pool in account \(protocolAddress) at path \(FlowCreditMarket.PoolPublicPath)")

    return pool.availableBalance(pid: pid, type: vaultType, pullFromTopUpSource: pullFromTopUpSource)
}
