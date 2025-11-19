import "FlowVaultsSchedulerProofs"

access(all) fun main(tideID: UInt64, scheduledTransactionID: UInt64): Bool {
    return FlowVaultsSchedulerProofs.wasExecuted(tideID: tideID, scheduledTransactionID: scheduledTransactionID)
}


