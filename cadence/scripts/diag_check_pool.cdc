import "EVM"

access(all) fun main(
    factoryHex: String,
    tokenAHex: String,
    tokenBHex: String,
    fee: UInt256
): String {
    let factory = EVM.addressFromString(factoryHex)
    let res = EVM.dryCall(
        from: factory,
        to: factory,
        data: EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)",
            [EVM.addressFromString(tokenAHex), EVM.addressFromString(tokenBHex), fee]
        ),
        gasLimit: 1_000_000,
        value: EVM.Balance(attoflow: 0)
    )
    if res.status != EVM.Status.successful {
        return "CALL FAILED: ".concat(res.errorMessage)
    }
    let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: res.data)
    if decoded.length == 0 { return "NO RESULT" }
    return (decoded[0] as! EVM.EVMAddress).toString()
}
