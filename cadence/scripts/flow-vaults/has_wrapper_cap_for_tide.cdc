import "FlowVaultsSchedulerRegistry"

/// Returns true if the scheduler registry has a handler capability (AutoBalancer)
/// stored for the given Tide ID.
/// Note: Uses isRegistered() since getHandlerCap is account-restricted for security.
access(all) fun main(tideID: UInt64): Bool {
    return FlowVaultsSchedulerRegistry.isRegistered(tideID: tideID)
}



