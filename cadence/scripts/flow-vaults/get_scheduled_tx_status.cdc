import "FlowTransactionScheduler"

/// Returns the status of a scheduled transaction by ID, or nil if unknown
///
/// @param id: The ID of the scheduled transaction
/// @return FlowTransactionScheduler.Status? - the status if available
///
access(all)
fun main(id: UInt64): FlowTransactionScheduler.Status? {
    return FlowTransactionScheduler.getStatus(id: id)
}


