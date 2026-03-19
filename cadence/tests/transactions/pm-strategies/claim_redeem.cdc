import "PMStrategiesV1"

/// Test transaction: calls the permissionless claimRedeem to complete
/// a pending deferred redemption.
///
/// @param yieldVaultID: The yield vault ID with a pending redeem
///
transaction(yieldVaultID: UInt64) {
    execute {
        PMStrategiesV1.claimRedeem(yieldVaultID: yieldVaultID)
    }
}
