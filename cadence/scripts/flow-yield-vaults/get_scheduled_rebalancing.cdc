import "FlowYieldVaultsSchedulerV1"

/// Returns information about a scheduled rebalancing transaction for a specific YieldVault.
///
/// @param account: The address of the account that scheduled the rebalancing
/// @param yieldVaultID: The ID of the YieldVault to query
/// @return Information about the scheduled rebalancing, or nil if none exists
///
access(all) fun main(account: Address, yieldVaultID: UInt64): FlowYieldVaultsSchedulerV1.RebalancingScheduleInfo? {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowYieldVaultsSchedulerV1.SchedulerManager>(
            FlowYieldVaultsSchedulerV1.SchedulerManagerPublicPath
        )
    if schedulerManager == nil {
        return nil
    }

    return schedulerManager!.getScheduledRebalancing(yieldVaultID: yieldVaultID)
}

