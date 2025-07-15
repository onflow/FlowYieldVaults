import "TidalYieldAutoBalancersV2"

/// Returns the current value of the AutoBalancerV2 related to the provided Tide ID or `nil` if none exists
///
access(all)
fun main(id: UInt64): UFix64? {
    return TidalYieldAutoBalancersV2.borrowAutoBalancer(id: id)?.currentValue()
} 