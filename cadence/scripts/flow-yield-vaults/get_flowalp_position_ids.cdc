import "FlowALPv0"

/// Returns all position IDs currently in the FlowALP pool at the hardcoded mainnet address.
/// Used in fork tests to snapshot existing positions before a test creates new ones.
access(all) fun main(): [UInt64] {
    let pool = getAccount(0x6b00ff876c299c61)
        .capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not borrow FlowALP pool")
    return pool.getPositionIDs()
}
