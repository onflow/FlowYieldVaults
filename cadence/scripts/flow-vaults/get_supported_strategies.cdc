import "FlowVaults"

/// Returns the Strategy Types currently supported by FlowVaults 
///
access(all) fun main(): [Type] {
    return FlowVaults.getSupportedStrategies()
}
