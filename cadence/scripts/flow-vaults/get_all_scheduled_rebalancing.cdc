import "FlowVaultsScheduler"

/// Returns information about all scheduled rebalancing transactions for an account.
///
/// @param account: The address of the account to query
/// @return An array of scheduled rebalancing information
///
access(all) fun main(account: Address): [FlowVaultsScheduler.RebalancingScheduleInfo] {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowVaultsScheduler.SchedulerManager>(
            FlowVaultsScheduler.SchedulerManagerPublicPath
        )
    
    if schedulerManager == nil {
        return []
    }

    return schedulerManager!.getAllScheduledRebalancing()
}

