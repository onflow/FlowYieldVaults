import "FlowVaults"

/// Returns the balance of the tide with the given ID at the provided address or nil if either the address does not
/// have a TideManager stored or the Tide is not available. Note this `nil` does not mean a Tide with the given ID
/// does not exist, solely that the Tide is not stored at the provided address.
///
/// @param address: The address of the account to look for the Tide
/// @param id: The ID of the Tide to query the balance of
///
/// @return the balance of the Tide or `nil` if the Tide was not found
///
access(all)
fun main(address: Address, id: UInt64): UFix64? {
    let tide = getAccount(address).capabilities.borrow<&FlowVaults.TideManager>(FlowVaults.TideManagerPublicPath)
        ?.borrowTide(id: id)
        ?? nil
    return tide?.getTideBalance() ?? nil
}
