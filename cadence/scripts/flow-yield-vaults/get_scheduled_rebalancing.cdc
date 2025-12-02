import "FlowYieldVaultsScheduler"

/// Returns information about a scheduled rebalancing transaction for a specific YieldVault.
///
/// @param account: The address of the account that scheduled the rebalancing
/// @param yieldVaultID: The ID of the YieldVault to query
/// @return Information about the scheduled rebalancing, or nil if none exists
///
access(all) fun main(account: Address, yieldVaultID: UInt64): FlowYieldVaultsScheduler.RebalancingScheduleInfo? {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowYieldVaultsScheduler.SchedulerManager>(
            FlowYieldVaultsScheduler.SchedulerManagerPublicPath
        )
    if schedulerManager == nil {
        return nil
    }

    return schedulerManager!.getScheduledRebalancing(yieldVaultID: yieldVaultID)
}

