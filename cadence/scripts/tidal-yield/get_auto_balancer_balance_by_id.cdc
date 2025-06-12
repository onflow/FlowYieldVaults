import "TidalYieldAutoBalancers"

access(all)
fun main(id: UInt64): UFix64? {
    return TidalYieldAutoBalancers.borrowAutoBalancer(id: id)?.vaultBalance()
}
