import "EVM"

access(all) fun main(poolAddress: String): {String: String} {
    // Parse pool address
    var poolAddrHex = poolAddress
    if poolAddress.slice(from: 0, upTo: 2) == "0x" {
        poolAddrHex = poolAddress.slice(from: 2, upTo: poolAddress.length)
    }
    let poolBytes = poolAddrHex.decodeHex()
    let poolAddr = EVM.EVMAddress(bytes: poolBytes.toConstantSized<[UInt8; 20]>()!)
    
    // Read slot0
    let slot0Data = EVM.load(target: poolAddr, slot: "0x0")
    
    if slot0Data.length == 0 {
        return {
            "success": "false",
            "error": "Pool not found or slot0 empty"
        }
    }
    
    // Parse slot0 (32 bytes)
    let slot0Int = UInt256.fromBigEndianBytes(slot0Data) ?? UInt256(0)
    
    // Extract sqrtPriceX96 (lower 160 bits)
    let mask160 = (UInt256(1) << 160) - 1
    let sqrtPriceX96 = slot0Int & mask160
    
    // Extract tick (bits 160-183, 24 bits signed)
    let tickU = (slot0Int >> 160) & ((UInt256(1) << 24) - 1)
    var tick = Int256(tickU)
    if tick >= Int256(1 << 23) {
        tick = tick - Int256(1 << 24)
    }
    
    // Calculate actual price from sqrtPriceX96
    // price = (sqrtPriceX96 / 2^96)^2
    // For display, we'll just show sqrtPriceX96 and tick
    // The user can verify: price ≈ 1.0001^tick
    
    return {
        "success": "true",
        "poolAddress": poolAddress,
        "sqrtPriceX96": sqrtPriceX96.toString(),
        "tick": tick.toString(),
        "slot0Raw": "0x".concat(String.encodeHex(slot0Data))
    }
}
