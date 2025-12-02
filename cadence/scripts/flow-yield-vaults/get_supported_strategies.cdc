import "FlowYieldVaults"

/// Returns the Strategy Types currently supported by FlowYieldVaults 
///
access(all) fun main(): [Type] {
    return FlowYieldVaults.getSupportedStrategies()
}
