import "FlowVaultsScheduler"

access(all) fun main(): [UInt64] {
    return FlowVaultsScheduler.getRegisteredTideIDs()
}


