import "FlowTransactionScheduler"
import "FlowYieldVaultsSchedulerV1"

/// Returns the current configuration of the Flow Transaction Scheduler.
///
/// This provides information about:
/// - Maximum and minimum execution effort limits
/// - Priority effort limits and reserves
/// - Fee multipliers for different priorities
/// - Refund policies
/// - Other scheduling constraints
///
/// @return The scheduler configuration
///
access(all) fun main(): {FlowTransactionScheduler.SchedulerConfig} {
    return FlowYieldVaultsSchedulerV1.getSchedulerConfig()
}

