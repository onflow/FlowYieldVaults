import "FlowVaultsAutoBalancers"

/// Returns true if the tide is stuck (overdue with no active schedule).
/// A tide is considered stuck if:
/// - It has a recurring config
/// - No active schedule exists
/// - The expected next execution time has passed
///
/// This is used by Supervisor to detect tides that failed to self-reschedule.
///
/// @param tideID: The tide/AutoBalancer ID
/// @return Bool: true if tide is stuck, false otherwise
///
access(all) fun main(tideID: UInt64): Bool {
    return FlowVaultsAutoBalancers.isStuckTide(id: tideID)
}

