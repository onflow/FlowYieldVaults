import "FlowYieldVaultsSchedulerV1"

/// Returns the IDs of all YieldVaults that have scheduled rebalancing transactions.
///
/// @param account: The address of the account to query
/// @return An array of YieldVault IDs with scheduled rebalancing
///
access(all) fun main(account: Address): [UInt64] {
    // Borrow the public capability for the SchedulerManager
    let schedulerManager = getAccount(account)
        .capabilities.borrow<&FlowYieldVaultsSchedulerV1.SchedulerManager>(
            FlowYieldVaultsSchedulerV1.SchedulerManagerPublicPath
        )
    
    if schedulerManager == nil {
        return []
    }

    return schedulerManager!.getScheduledYieldVaultIDs()
}

