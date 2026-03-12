import "PMStrategiesV1"

access(all) fun main(yieldVaultID: UInt64): PMStrategiesV1.PendingRedeemInfo? {
    return PMStrategiesV1.getPendingRedeemInfo(yieldVaultID: yieldVaultID)
}
