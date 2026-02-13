import "EVM"

access(all) fun main(poolAddress: String): {String: String} {
    let coa = getAuthAccount<auth(Storage) &Account>(0xe467b9dd11fa00df)
        .storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
        ?? panic("Could not borrow COA")
    
    let results: {String: String} = {}
    let pool = EVM.addressFromString(poolAddress)
    
    // Check slot0 (has price info)
    var calldata = EVM.encodeABIWithSignature("slot0()", [])
    var result = coa.dryCall(to: pool, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    results["slot0_status"] = result.status.rawValue.toString()
    results["slot0_data_length"] = result.data.length.toString()
    results["slot0_data"] = String.encodeHex(result.data)
    
    // Check liquidity
    calldata = EVM.encodeABIWithSignature("liquidity()", [])
    result = coa.dryCall(to: pool, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    results["liquidity_status"] = result.status.rawValue.toString()
    results["liquidity_data"] = String.encodeHex(result.data)
    
    return results
}
