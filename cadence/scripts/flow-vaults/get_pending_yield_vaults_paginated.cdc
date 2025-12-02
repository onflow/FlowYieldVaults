import "FlowVaultsSchedulerRegistry"

/// Returns a paginated list of yield vault IDs in the pending queue.
/// @param page: The page number (0-indexed)
/// @param size: The number of yield vaults per page (defaults to MAX_BATCH_SIZE if 0)
access(all) fun main(page: Int, size: Int): [UInt64] {
    let pageSize: Int? = size > 0 ? size : nil
    return FlowVaultsSchedulerRegistry.getPendingYieldVaultIDsPaginated(page: page, size: pageSize)
}

