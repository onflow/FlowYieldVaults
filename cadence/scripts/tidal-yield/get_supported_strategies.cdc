import "TidalYield"

/// Returns the Strategy Types currently supported by TidalYield
///
access(all) fun main(): [Type] {
    return TidalYield.getSupportedStrategies()
}
