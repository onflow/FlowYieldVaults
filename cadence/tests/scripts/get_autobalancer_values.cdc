import "FlowYieldVaultsAutoBalancers"

access(all) fun main(id: UInt64): {String: String} {
    let results: {String: String} = {}
    
    let autoBalancer = FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id)
        ?? panic("Could not borrow AutoBalancer")
    
    // Get the critical values
    results["balance"] = autoBalancer.vaultBalance().toString()
    results["currentValue"] = autoBalancer.currentValue()?.toString() ?? "nil"
    results["valueOfDeposits"] = autoBalancer.valueOfDeposits().toString()
    
    return results
}
