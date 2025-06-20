import "TidalProtocol"

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): UFix64 {
    let protocolAddress= Type<@TidalProtocol.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?.positionHealth(pid: pid)
        ?? panic("Could not find a configured TidalProtocol Pool in account \(protocolAddress) at path \(TidalProtocol.PoolPublicPath)")
}
