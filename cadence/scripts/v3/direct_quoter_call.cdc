import "EVM"
import "EVMAbiHelpers"

/// Direct V3 quoter call - bypass all the complex swapper logic
/// Just make a raw EVM call to the quoter contract
access(all) fun main(amountIn: UInt256): String {
    // Get COA
    let account = getAuthAccount<auth(Storage, Capabilities, BorrowValue) &Account>(0x045a1763c93006ca)
    let coaRef = account.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
        ?? panic("No COA found")
    
    let quoterAddr = EVM.addressFromString("0x14885A6C9d1a9bDb22a9327e1aA7730e60F79399")
    
    // Build path: USDC(20 bytes) + fee(3 bytes) + MOET(20 bytes) = 43 bytes
    let usdcBytes: [UInt8; 20] = [
        0x8C,0x71,0x87,0x93,0x2B,0x86,0x2F,0x96,0x2F,0x14,
        0x71,0xC6,0xE6,0x94,0xAE,0xFF,0xB9,0xF5,0x28,0x6D
    ]
    let feeBytes: [UInt8; 3] = [0x00, 0x0B, 0xB8]  // 3000 = 0x0BB8
    let moetBytes: [UInt8; 20] = [
        0x9A,0x7B,0x1D,0x14,0x48,0x28,0xC3,0x56,0xEC,0x23,
        0xEC,0x86,0x28,0x43,0xFC,0xA4,0xA8,0xFF,0x82,0x9E
    ]
    
    // Combine into path
    var pathBytes: [UInt8] = []
    var i = 0
    while i < 20 { pathBytes.append(usdcBytes[i]); i = i + 1 }
    pathBytes.append(feeBytes[0])
    pathBytes.append(feeBytes[1])
    pathBytes.append(feeBytes[2])
    i = 0
    while i < 20 { pathBytes.append(moetBytes[i]); i = i + 1 }
    
    // Build calldata for quoteExactInput(bytes path, uint256 amountIn)
    let selector: [UInt8] = [0xcd, 0xca, 0x17, 0x53]  // quoteExactInput selector
    
    // Encode: selector + offset(32) + amountIn(32) + path_length(32) + path_data
    var calldata: [UInt8] = selector
    
    // Add offset to path (64 = 0x40)
    let offsetBytes = EVMAbiHelpers.abiWord(UInt256(64))
    calldata.appendAll(offsetBytes)
    
    // Add amountIn
    let amountBytes = EVMAbiHelpers.abiWord(amountIn)
    calldata.appendAll(amountBytes)
    
    // Add path as dynamic bytes
    let pathEncoded = EVMAbiHelpers.abiDynamicBytes(pathBytes)
    calldata.appendAll(pathEncoded)
    
    // Make call
    let result = coaRef.call(
        to: quoterAddr,
        data: calldata,
        gasLimit: 1_000_000,
        value: EVM.Balance(attoflow: 0)
    )
    
    if result.status != EVM.Status.successful {
        return "CALL FAILED: status=".concat(result.status.rawValue.toString())
    }
    
    // Decode result (should be uint256)
    let resultData = result.data
    if resultData.length < 32 {
        return "RESULT TOO SHORT: ".concat(resultData.length.toString()).concat(" bytes")
    }
    
    // Decode the uint256 result
    let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: resultData)
    if decoded.length == 0 {
        return "DECODE FAILED"
    }
    
    let quoteOut = decoded[0] as! UInt256
    return "SUCCESS: Quote for ".concat(amountIn.toString()).concat(" = ").concat(quoteOut.toString())
}

