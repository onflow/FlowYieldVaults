import "PMStrategiesV1"

access(all) fun main(yieldVaultID: UInt64): UFix64? {
    if let ref = PMStrategiesV1.getScheduledClaim(yieldVaultID: yieldVaultID) {
        return ref.timestamp
    }
    return nil
}
