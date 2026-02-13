import "EVM"

access(all) fun main(vaultAddress: String): {String: String} {
    let vault = EVM.addressFromString(vaultAddress)
    let dummy = EVM.addressFromString("0x0000000000000000000000000000000000000001")
    
    // Call totalAssets()
    let assetsCalldata = EVM.encodeABIWithSignature("totalAssets()", [])
    let assetsResult = EVM.call(
        from: dummy.toString(),
        to: vaultAddress,
        data: assetsCalldata,
        gasLimit: 100000,
        value: 0
    )
    
    // Call totalSupply()
    let supplyCalldata = EVM.encodeABIWithSignature("totalSupply()", [])
    let supplyResult = EVM.call(
        from: dummy.toString(),
        to: vaultAddress,
        data: supplyCalldata,
        gasLimit: 100000,
        value: 0
    )
    
    if assetsResult.status != EVM.Status.successful || supplyResult.status != EVM.Status.successful {
        return {
            "totalAssets": "0",
            "totalSupply": "0",
            "price": "0"
        }
    }
    
    let totalAssets = EVM.decodeABI(types: [Type<UInt256>()], data: assetsResult.data)[0] as! UInt256
    let totalSupply = EVM.decodeABI(types: [Type<UInt256>()], data: supplyResult.data)[0] as! UInt256
    
    // Price with 1e18 scale: (totalAssets * 1e18) / totalSupply
    // For PYUSD0 (6 decimals), we scale to 18 decimals
    let price = totalSupply > UInt256(0) ? (totalAssets * UInt256(1000000000000)) / totalSupply : UInt256(0)
    
    return {
        "totalAssets": totalAssets.toString(),
        "totalSupply": totalSupply.toString(),
        "price": price.toString()
    }
}
