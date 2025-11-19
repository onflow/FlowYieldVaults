import "EVM"

/// Runs a raw, signed EVM transaction (RLP bytes) inside Flow EVM.
transaction(rawHex: String, coinbaseHex: String) {
    prepare(_: auth(BorrowValue) &Account) {
        // 1) Decode raw tx
        let rawTx: [UInt8] = rawHex.decodeHex()

        // 2) Parse coinbase (fee receiver) as EVM address
        //    Use the EVM address of a CadenceOwnedAccount you control,
        //    or "000...0000" to send fees to the zero address (not recommended).
        let coinbase: EVM.EVMAddress = EVM.addressFromString(coinbaseHex)

        // 3) Execute (fails early if status is unknown/invalid)
        let res: EVM.Result = EVM.mustRun(tx: rawTx, coinbase: coinbase)

        log("⛽ gasUsed: ".concat(res.gasUsed.toString()))
        log("📦 status: ".concat(res.status.rawValue.toString())) // 0=unknown,1=invalid,2=failed,3=successful
        log("❗ errorCode: ".concat(res.errorCode.toString()))
        if res.errorMessage.length > 0 {
            log("📝 errorMessage: ".concat(res.errorMessage))
        }

        // Returned data (e.g. contract code on deploy, or revert data)
        if res.data.length > 0 {
            log("🔙 returnedData (hex): ".concat(String.encodeHex(res.data)))
        }

        // If this tx deployed a contract, show its address
        if let deployed = res.deployedContract {
            log("🏠 deployed at: ".concat(deployed.toString()))
        }
    }
}
