import "TidalProtocol"

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): TidalProtocol.PositionDetails {
    let protocolAddress= Type<@TidalProtocol.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?.getPositionDetails(pid: pid)
        ?? panic("Could not find a configured TidalProtocol Pool in account \(protocolAddress) at path \(TidalProtocol.PoolPublicPath)")
}
