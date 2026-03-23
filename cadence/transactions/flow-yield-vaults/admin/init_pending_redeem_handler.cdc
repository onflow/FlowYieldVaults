import "PMStrategiesV1"

/// Initializes the PendingRedeemHandler in the PMStrategiesV1 contract account.
/// Idempotent — safe to call multiple times; no-op if handler already exists.
/// No signer required: the function writes only to the contract's own storage.
transaction() {
    execute {
        PMStrategiesV1.initPendingRedeemHandler()
    }
}
