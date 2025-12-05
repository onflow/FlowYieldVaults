import "FlowYieldVaultsClosedBeta"

/// Self-grant beta when you own the FlowYieldVaultsClosedBeta contract
/// Simpler version for testing on fresh account
transaction() {
    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Borrow the AdminHandle (should exist since we deployed FlowYieldVaultsClosedBeta)
        let handle = signer.storage.borrow<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
            from: FlowYieldVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle at \(FlowYieldVaultsClosedBeta.AdminHandleStoragePath)")
        
        // Grant beta to self
        let cap = handle.grantBeta(addr: signer.address)
        
        // Save the beta capability
        let storagePath = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        
        // Remove any existing capability
        if let existing = signer.storage.load<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(from: storagePath) {
            // Old cap exists, remove it
        }
        
        // Save the new capability
        signer.storage.save(cap, to: storagePath)
        
        log("✅ Beta granted to self!")
        log("   StoragePath: ".concat(storagePath.toString()))
    }
}

