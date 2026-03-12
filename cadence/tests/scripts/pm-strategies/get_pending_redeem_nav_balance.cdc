import "PMStrategiesV1"

access(all) fun main(yieldVaultID: UInt64): UFix64 {
    return PMStrategiesV1.getPendingRedeemNAVBalance(yieldVaultID: yieldVaultID)
}
