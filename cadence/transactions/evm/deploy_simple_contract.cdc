import "EVM"

/// Deploys a Solidity contract to EVM via COA
/// @param bytecodeHex: The contract bytecode as a hex string (without 0x prefix)
transaction(bytecodeHex: String) {
    prepare(signer: auth(Storage, SaveValue) &Account) {
        // Get or create COA with Owner authorization
        var coaRef = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
        if coaRef == nil {
            let coa <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-coa, to: /storage/evm)
            coaRef = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
        }
        
        let coa = coaRef!
        
        // Convert hex string to byte array
        var code: [UInt8] = []
        var i = 0
        
        // Remove 0x prefix if present
        var hex = bytecodeHex
        if hex.slice(from: 0, upTo: 2) == "0x" {
            hex = hex.slice(from: 2, upTo: hex.length)
        }
        
        // Parse hex bytes (UInt8.fromString now requires 0x prefix)
        while i < hex.length {
            if i + 2 <= hex.length {
                let byteStr = "0x".concat(hex.slice(from: i, upTo: i + 2))
                if let byte = UInt8.fromString(byteStr) {
                    code.append(byte)
                }
            }
            i = i + 2
        }
        
        // Deploy contract
        let deployResult = coa.deploy(
            code: code,
            gasLimit: 15000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        // deployResult is EVM.Result type - just log gas used for now
        log("✅ Contract deployed successfully")
        log("   Gas used: ".concat(deployResult.gasUsed.toString()))
        log("   Status: ".concat(deployResult.status == EVM.Status.successful ? "success" : "failed"))
    }
}

