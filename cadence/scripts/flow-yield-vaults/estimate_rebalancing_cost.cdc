import "FlowTransactionScheduler"
import "FlowYieldVaultsScheduler"

/// Estimates the cost of scheduling a rebalancing transaction.
///
/// This script helps determine how much FLOW is needed to schedule a rebalancing
/// transaction with the specified parameters. Use this before calling schedule_rebalancing
/// to ensure you have sufficient funds.
///
/// @param timestamp: The desired execution timestamp (Unix timestamp)
/// @param priorityRaw: The priority level as a UInt8 (0=High, 1=Medium, 2=Low)
/// @param executionEffort: The computational effort to allocate (typical: 100-1000)
/// @return An estimate containing the required fee and actual scheduled timestamp
///
/// Example return value:
/// {
///   flowFee: 0.001,           // Amount of FLOW needed
///   timestamp: 1699920000.0,  // When it will actually execute
///   error: nil                // Any error message (nil if successful)
/// }
///
access(all) fun main(
    timestamp: UFix64,
    priorityRaw: UInt8,
    executionEffort: UInt64
): FlowTransactionScheduler.EstimatedScheduledTransaction {
    // Convert the raw priority value to the enum
    let priority: FlowTransactionScheduler.Priority = priorityRaw == 0 
        ? FlowTransactionScheduler.Priority.High
        : (priorityRaw == 1 
            ? FlowTransactionScheduler.Priority.Medium 
            : FlowTransactionScheduler.Priority.Low)

    return FlowYieldVaultsScheduler.estimateSchedulingCost(
        timestamp: timestamp,
        priority: priority,
        executionEffort: executionEffort
    )
}

