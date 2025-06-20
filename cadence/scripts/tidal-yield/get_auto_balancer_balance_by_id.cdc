import "TidalYieldAutoBalancers"

/// Returns the balance of the AutoBalancer related to the provided Tide ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return TidalYieldAutoBalancers.borrowAutoBalancer(id: id)?.vaultBalance()
}
