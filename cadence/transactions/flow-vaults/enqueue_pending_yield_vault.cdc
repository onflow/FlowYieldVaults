import "FlowVaultsSchedulerRegistry"

/// [ADMIN/TEST ONLY] Manually adds a yield vault to the pending queue for Supervisor re-seeding.
///
/// IMPORTANT: This transaction can ONLY be signed by the FlowVaults contract account
/// because enqueuePending requires account-level access. This is a security measure
/// to prevent gaming the pending queue.
///
/// In normal operation:
/// - Supervisor automatically detects stuck yield vaults (via isStuckYieldVault check)
/// - Supervisor adds stuck yield vaults to pending queue internally
/// - Supervisor then schedules them via SchedulerManager
///
/// This transaction is only for:
/// - Admin emergency recovery
/// - Testing the pending queue behavior
///
/// @param yieldVaultID: The ID of the yield vault to enqueue for re-seeding
///
transaction(yieldVaultID: UInt64) {
    prepare(signer: auth(BorrowValue) &Account) {
        // This will only work if signer is the FlowVaultsSchedulerRegistry contract account
        // because enqueuePending has access(account)
    }

    execute {
        // Only the contract account can call this
        FlowVaultsSchedulerRegistry.enqueuePending(yieldVaultID: yieldVaultID)
    }
}

