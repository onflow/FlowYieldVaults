import "EVM"

/// Creates a Cadence-Owned Account (COA) for EVM interaction
transaction {
    prepare(signer: auth(Storage, SaveValue) &Account) {
        // Check if COA already exists
        if signer.storage.type(at: /storage/evm) != nil {
            log("COA already exists")
            return
        }
        
        // Create new COA
        let coa <- EVM.createCadenceOwnedAccount()
        
        // Save to storage
        signer.storage.save(<-coa, to: /storage/evm)
        
        log("✅ COA created and saved to /storage/evm")
    }
}

