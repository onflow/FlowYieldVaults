import "FlowYieldVaultsAutoBalancersV1"

access(all)
fun main(id: UInt64): UFix64? {
    return FlowYieldVaultsAutoBalancersV1.borrowAutoBalancer(id: id)?.vaultBalance()
}
