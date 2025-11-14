import "FlowALP"

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): UFix128 {
    let protocolAddress= Type<@FlowALP.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?.positionHealth(pid: pid)
        ?? panic("Could not find a configured FlowALP Pool in account \(protocolAddress) at path \(FlowALP.PoolPublicPath)")
}
