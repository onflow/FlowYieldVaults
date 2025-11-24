import "FlowVaultsSchedulerRegistry"

/// Returns true if the scheduler registry has a wrapper capability stored for
/// the given Tide ID.
access(all) fun main(tideID: UInt64): Bool {
    return FlowVaultsSchedulerRegistry.getWrapperCap(tideID: tideID) != nil
}



