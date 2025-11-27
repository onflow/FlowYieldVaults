import "FlowVaultsSchedulerRegistry"

/// Returns the count of registered tides in the registry
///
/// @return Int: The number of registered tides
///
access(all) fun main(): Int {
    return FlowVaultsSchedulerRegistry.getRegisteredTideIDs().length
}

