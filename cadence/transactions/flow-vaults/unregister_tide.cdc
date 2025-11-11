import "FlowVaultsScheduler"

/// Unregisters a Tide ID from supervision. Must be run by the FlowVaults (tidal) account.
transaction(tideID: UInt64) {
    prepare(_ signer: auth(BorrowValue) &Account) {
        FlowVaultsScheduler.unregisterTide(tideID: tideID)
    }
}


