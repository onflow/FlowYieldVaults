import "FlowVaultsClosedBeta"

/// Self-grant beta when you own the FlowVaultsClosedBeta contract
/// Simpler version for testing on fresh account
transaction() {
    prepare(signer: auth(Storage, BorrowValue, Capabilities) &Account) {
        // Borrow the AdminHandle (should exist since we deployed FlowVaultsClosedBeta)
        let handle = signer.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
            from: FlowVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle at \(FlowVaultsClosedBeta.AdminHandleStoragePath)")
        
        // Grant beta to self
        let cap = handle.grantBeta(addr: signer.address)
        
        // Save the beta capability
        let storagePath = FlowVaultsClosedBeta.UserBetaCapStoragePath
        
        // Remove any existing capability
        if let existing = signer.storage.load<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: storagePath) {
            // Old cap exists, remove it
        }
        
        // Save the new capability
        signer.storage.save(cap, to: storagePath)
        
        log("✅ Beta granted to self!")
        log("   StoragePath: ".concat(storagePath.toString()))
    }
}

