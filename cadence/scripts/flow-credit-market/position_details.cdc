import "FlowCreditMarket"

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): FlowCreditMarket.PositionDetails {
    let protocolAddress= Type<@FlowCreditMarket.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?.getPositionDetails(pid: pid)
        ?? panic("Could not find a configured FlowCreditMarket Pool in account \(protocolAddress) at path \(FlowCreditMarket.PoolPublicPath)")
}
