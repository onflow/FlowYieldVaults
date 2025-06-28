import "TidalYieldAutoBalancers"

/// Returns the current value of the AutoBalancer's balance related to the provided Tide ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return TidalYieldAutoBalancers.borrowAutoBalancer(id: id)?.currentValue() ?? nil
}
