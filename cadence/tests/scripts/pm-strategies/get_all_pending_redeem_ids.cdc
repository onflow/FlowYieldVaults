import "PMStrategiesV1"

access(all) fun main(): [UInt64] {
    return PMStrategiesV1.getAllPendingRedeemIDs()
}
