import "EVM"

/// Transfers ERC-20 tokens from the signer's COA to any EVM address (e.g., a UniswapV3 pool).
/// This is useful for adding liquidity to pools in forked tests.
///
/// @param tokenAddressHex: The ERC-20 token contract address (hex string)
/// @param recipientAddressHex: The recipient EVM address (pool, wallet, or contract)
/// @param amount: The amount to transfer (in token's smallest unit, e.g., wei)
///
transaction(tokenAddressHex: String, recipientAddressHex: String, amount: UInt256) {

    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    let tokenAddress: EVM.EVMAddress
    let recipientAddress: EVM.EVMAddress

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA from signer's storage. Ensure the account has a CadenceOwnedAccount at /storage/evm")

        self.tokenAddress = EVM.addressFromString(tokenAddressHex)
        self.recipientAddress = EVM.addressFromString(recipientAddressHex)
    }

    execute {
        // Encode ERC-20 transfer(address,uint256) call
        let transferCalldata = EVM.encodeABIWithSignature(
            "transfer(address,uint256)",
            [self.recipientAddress, amount]
        )

        // Execute the transfer from COA
        let result = self.coa.call(
            to: self.tokenAddress,
            data: transferCalldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "ERC-20 transfer failed: ".concat(result.errorMessage)
        )

        // Decode the return value (bool success)
        if result.data.length > 0 {
            let decoded = EVM.decodeABI(types: [Type<Bool>()], data: result.data)
            let success = decoded[0] as! Bool
            assert(success, message: "ERC-20 transfer returned false")
        }

        log("Successfully transferred ".concat(amount.toString()).concat(" tokens"))
        log("From COA: ".concat(self.coa.address().toString()))
        log("To: ".concat(self.recipientAddress.toString()))
    }
}
