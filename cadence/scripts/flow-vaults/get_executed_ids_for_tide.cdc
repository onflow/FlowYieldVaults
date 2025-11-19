import "FlowVaultsSchedulerProofs"

access(all) fun main(tideID: UInt64): [UInt64] {
    return FlowVaultsSchedulerProofs.getExecutedIDs(tideID: tideID)
}


