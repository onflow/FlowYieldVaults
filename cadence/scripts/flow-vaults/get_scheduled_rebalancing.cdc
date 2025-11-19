import "FlowVaultsScheduler"

/// Returns information about a scheduled rebalancing transaction for a specific Tide.
///
/// @param account: The address of the account that scheduled the rebalancing
/// @param tideID: The ID of the Tide to query
/// @return Information about the scheduled rebalancing, or nil if none exists
///
access(all) fun main(account: Address, tideID: UInt64): FlowVaultsScheduler.RebalancingScheduleInfo? {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowVaultsScheduler.SchedulerManager>(
            FlowVaultsScheduler.SchedulerManagerPublicPath
        )
    if schedulerManager == nil {
        return nil
    }

    return schedulerManager!.getScheduledRebalancing(tideID: tideID)
}

