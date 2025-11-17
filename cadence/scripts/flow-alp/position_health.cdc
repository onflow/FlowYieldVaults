import "FlowALP"

/// Returns the position health for a given position id, reverting if the position does not exist.
///
/// @param pid: The Position ID
/// NOTE: `FlowALP.Pool.positionHealth` returns `UFix128`, so this script returns
/// `UFix128` as well for full precision. Off-chain callers that only need a
/// floating-point approximation can safely cast to `Float`/`UFix64`.
access(all)
fun main(pid: UInt64): UFix128 {
    let protocolAddress = Type<@FlowALP.Pool>().address!
    return getAccount(protocolAddress)
        .capabilities
        .borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?.positionHealth(pid: pid)
        ?? panic("Could not find a configured FlowALP Pool in account \(protocolAddress) at path \(FlowALP.PoolPublicPath)")
}
