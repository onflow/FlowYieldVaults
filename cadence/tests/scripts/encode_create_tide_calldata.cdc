import "EVM"
import "EVMAbiHelpers"

/// Encodes calldata for createTide(address,uint256,string,string)
access(all) fun main(
    tokenAddressHex: String,
    amount: UInt256,
    vaultIdentifier: String,
    strategyIdentifier: String
): String {
    let abiHelpers = EVMAbiHelpers
    
    // Function selector: createTide(address,uint256,string,string) = 0x4ebb0a7e
    let selector = "4ebb0a7e".decodeHex()
    
    // Encode address
    let tokenAddress = EVM.addressFromString(tokenAddressHex)
    let encodedAddress = abiHelpers.abiAddress(tokenAddress)
    
    // Encode amount
    let encodedAmount = abiHelpers.abiUInt256(amount)
    
    // Encode strings
    let encodedVaultId = abiHelpers.abiStringFromUTF8(vaultIdentifier.utf8)
    let encodedStrategyId = abiHelpers.abiStringFromUTF8(strategyIdentifier.utf8)
    
    // Build calldata
    let args: [EVMAbiHelpers.ABIArg] = [
        abiHelpers.staticArg(encodedAddress),
        abiHelpers.staticArg(encodedAmount),
        abiHelpers.dynamicArg(encodedVaultId),
        abiHelpers.dynamicArg(encodedStrategyId)
    ]
    
    let calldataBytes = abiHelpers.buildCalldata(selector: selector, args: args)
    return String.encodeHex(calldataBytes)
}

