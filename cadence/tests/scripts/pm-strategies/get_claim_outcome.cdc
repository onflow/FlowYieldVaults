import "PMStrategiesV1"

access(all) fun main(yieldVaultID: UInt64): String? {
    return PMStrategiesV1.getClaimOutcome(yieldVaultID: yieldVaultID)
}
