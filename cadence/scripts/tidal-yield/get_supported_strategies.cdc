import "Tidal"

/// Returns the Strategy Types currently supported by Tidal
///
access(all) fun main(): [Type] {
    return Tidal.getSupportedStrategies()
}
