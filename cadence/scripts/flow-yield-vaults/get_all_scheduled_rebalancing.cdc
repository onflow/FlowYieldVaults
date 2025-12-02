import "FlowYieldVaultsScheduler"

/// Returns information about all scheduled rebalancing transactions for an account.
///
/// @param account: The address of the account to query
/// @return An array of scheduled rebalancing information
///
access(all) fun main(account: Address): [FlowYieldVaultsScheduler.RebalancingScheduleInfo] {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowYieldVaultsScheduler.SchedulerManager>(
            FlowYieldVaultsScheduler.SchedulerManagerPublicPath
        )
    
    if schedulerManager == nil {
        return []
    }

    return schedulerManager!.getAllScheduledRebalancing()
}

