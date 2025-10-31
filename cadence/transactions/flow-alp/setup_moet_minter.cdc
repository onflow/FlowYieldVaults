import "MOET"

/// Sets up a MOET Minter in the FlowALP account so it can mint MOET during rebalancing
/// This is a workaround for the current implementation where FlowALP expects to have
/// its own MOET minter for rebalancing operations
///
transaction {
    prepare(signer: auth(SaveValue) &Account) {
        // Check if minter already exists
        if signer.storage.type(at: MOET.AdminStoragePath) == nil {
            // Create a new MOET minter (this is allowed by the MOET contract)
            let minter <- create MOET.Minter()
            
            // Save the minter to FlowALP's storage at the expected path
            signer.storage.save(<-minter, to: MOET.AdminStoragePath)
        }
    }
} 
