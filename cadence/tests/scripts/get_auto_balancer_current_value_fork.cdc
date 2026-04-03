import "FlowYieldVaultsAutoBalancers"

access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)?.currentValue() ?? nil
}
