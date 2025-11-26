import "FlowVaultsSchedulerRegistry"

/// Returns true if the scheduler registry has a handler capability (AutoBalancer)
/// stored for the given Tide ID.
access(all) fun main(tideID: UInt64): Bool {
    return FlowVaultsSchedulerRegistry.getHandlerCap(tideID: tideID) != nil
}



