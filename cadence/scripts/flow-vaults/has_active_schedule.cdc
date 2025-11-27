import "FlowVaultsAutoBalancers"

/// Returns true if the tide/AutoBalancer has at least one active (Scheduled) transaction.
/// Used to verify that healthy tides maintain their scheduling chain.
///
/// @param tideID: The tide/AutoBalancer ID
/// @return Bool: true if there's at least one Scheduled transaction, false otherwise
///
access(all) fun main(tideID: UInt64): Bool {
    return FlowVaultsAutoBalancers.hasActiveSchedule(id: tideID)
}

