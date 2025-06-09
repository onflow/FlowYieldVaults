import "TidalYield"

/// Retrieves the IDs of Tides configured at the provided address or `nil` if a TideManager is not stored
///
/// @param address: The address of the Flow account in question
///
/// @return A UInt64 array of all Tide IDs stored in the account's TideManager
access(all)
fun main(address: Address): [UInt64]? {
    return getAccount(address).capabilities.borrow<&TidalYield.TideManager>(TidalYield.TideManagerPublicPath)
        ?.getIDs()
}
