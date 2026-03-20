import "PMStrategiesV1"

/// Test transaction: calls the permissionless claimRedeem to complete a pending
/// deferred redemption or recover shares after an EVM redeem revert.
///
/// @param yieldVaultID: The yield vault ID with a pending redeem
///
transaction(yieldVaultID: UInt64) {
    execute {
        PMStrategiesV1.claimRedeem(yieldVaultID: yieldVaultID)
    }
}
