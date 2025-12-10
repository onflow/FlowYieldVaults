import "EVM"

/// Executes the calldata and returns the EVM result
///
access(all) fun main(
    gatewayAddress: Address,
    evmContractAddressHex: String,
    calldata: String,
    gasLimit: UInt64,
    value: UInt
): EVM.Result {
    let evmAddress = EVM.addressFromString(evmContractAddressHex)
    let data = calldata.decodeHex()

    let gatewayCOA = getAuthAccount<auth(BorrowValue) &Account>(gatewayAddress)
        .storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA from provided gateway address")

    let valueBalance = EVM.Balance(attoflow: value)
    let evmResult = gatewayCOA.call(
        to: evmAddress,
        data: data,
        gasLimit: gasLimit,
        value: valueBalance
    )

    return evmResult
}

