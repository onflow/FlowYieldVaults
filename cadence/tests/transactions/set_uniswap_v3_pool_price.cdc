import EVM from "EVM"

// Helper: Compute Solidity mapping storage slot
access(all) fun computeMappingSlot(_ values: [AnyStruct]): String {
    let encoded = EVM.encodeABI(values)
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)
    return "0x".concat(String.encodeHex(hashBytes))
}

// Helper: Compute ERC20 balanceOf storage slot
access(all) fun computeBalanceOfSlot(holderAddress: String, balanceSlot: UInt256): String {
    var addrHex = holderAddress
    if holderAddress.slice(from: 0, upTo: 2) == "0x" {
        addrHex = holderAddress.slice(from: 2, upTo: holderAddress.length)
    }
    let addrBytes = addrHex.decodeHex()
    let address = EVM.EVMAddress(bytes: addrBytes.toConstantSized<[UInt8; 20]>()!)
    return computeMappingSlot([address, balanceSlot])
}

// Properly seed Uniswap V3 pool with STRUCTURALLY VALID state
// This creates: slot0, observations, liquidity, ticks (with initialized flag), bitmap, and token balances
transaction(
    factoryAddress: String,
    token0Address: String,
    token1Address: String,
    fee: UInt64,
    targetSqrtPriceX96: String,
    targetTick: Int256,
    token0BalanceSlot: UInt256,
    token1BalanceSlot: UInt256
) {
    prepare(signer: &Account) {}

    execute {
        let factory = EVM.addressFromString(factoryAddress)
        let token0 = EVM.addressFromString(token0Address)
        let token1 = EVM.addressFromString(token1Address)
        
        log("\n=== SEEDING V3 POOL ===")
        log("Factory: \(factoryAddress)")
        log("Token0: \(token0Address)")
        log("Token1: \(token1Address)")
        log("Fee: \(fee)")
        
        // 1. Get pool address from factory (NOT hardcoded!)
        let getPoolCalldata = EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)",
            [token0, token1, UInt256(fee)]
        )
        let getPoolResult = EVM.call(
            from: factoryAddress,
            to: factoryAddress,
            data: getPoolCalldata,
            gasLimit: 100000,
            value: 0
        )
        
        if getPoolResult.status != EVM.Status.successful {
            panic("Failed to get pool address")
        }
        
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: getPoolResult.data)
        let poolAddr = decoded[0] as! EVM.EVMAddress
        let poolAddress = poolAddr.toString()
        log("Pool address: \(poolAddress)")
        
        // Check pool exists
        var isZero = true
        for byte in poolAddr.bytes {
            if byte != 0 {
                isZero = false
                break
            }
        }
        assert(!isZero, message: "Pool does not exist - create it first")
        
        // 2. Read pool parameters (tickSpacing is CRITICAL)
        let tickSpacingCalldata = EVM.encodeABIWithSignature("tickSpacing()", [])
        let spacingResult = EVM.call(
            from: poolAddress,
            to: poolAddress,
            data: tickSpacingCalldata,
            gasLimit: 100000,
            value: 0
        )
        assert(spacingResult.status == EVM.Status.successful, message: "Failed to read tickSpacing")
        
        let tickSpacing = (EVM.decodeABI(types: [Type<Int256>()], data: spacingResult.data)[0] as! Int256)
        log("Tick spacing: \(tickSpacing.toString())")
        
        // Round targetTick to nearest tickSpacing multiple
        // NOTE: In real Uniswap V3, slot0.tick doesn't need to be on tickSpacing boundaries
        // (only initialized ticks with liquidity do). However, rounding here ensures consistency
        // and avoids potential edge cases. The price difference is minimal (e.g., ~0.16% for tick 
        // 6931→6900). We may revisit this if exact prices become critical.
        // TODO: Consider passing unrounded tick to slot0 if precision matters
        let targetTickAligned = (targetTick / tickSpacing) * tickSpacing
        log("Target tick (raw): \(targetTick.toString()), aligned: \(targetTickAligned.toString())")
        
        // 3. Calculate full-range ticks (MUST be multiples of tickSpacing!)
        let tickLower = Int256(-887272) / tickSpacing * tickSpacing
        let tickUpper = Int256(887272) / tickSpacing * tickSpacing
        log("Full-range ticks: \(tickLower.toString()) to \(tickUpper.toString())")
        
        // 4. Set slot0 with target price
        // slot0 packing (from lowest to highest bits):
        //   sqrtPriceX96 (160 bits)
        //   tick (24 bits, signed)
        //   observationIndex (16 bits)
        //   observationCardinality (16 bits)
        //   observationCardinalityNext (16 bits)
        //   feeProtocol (8 bits)
        //   unlocked (8 bits)

        // Pack slot0 correctly for Solidity storage layout
        // In Solidity, the struct is packed right-to-left (LSB to MSB):
        //   sqrtPriceX96 (160 bits) | tick (24 bits) | observationIndex (16 bits) | 
        //   observationCardinality (16 bits) | observationCardinalityNext (16 bits) | 
        //   feeProtocol (8 bits) | unlocked (8 bits)
        // 
        // Storage is a 32-byte (256-bit) word, packed from right to left.
        // We build the byte array in BIG-ENDIAN order (as it will be stored).

        // Parse sqrtPriceX96 as UInt256
        let sqrtPriceU256 = UInt256.fromString(targetSqrtPriceX96)!
        
        // Convert tick to 24-bit representation (with two's complement for negative)
        let tickMask = UInt256((Int256(1) << 24) - 1)  // 0xFFFFFF
        let tickU = UInt256(
            targetTickAligned < Int256(0) 
                ? (Int256(1) << 24) + targetTickAligned  // Two's complement for negative
                : targetTickAligned
        ) & tickMask
        
        // Now pack everything into a UInt256
        // Formula: value = sqrtPrice + (tick << 160) + (obsIndex << 184) + (obsCard << 200) + 
        //                 (obsCardNext << 216) + (feeProtocol << 232) + (unlocked << 240)
        
        var packedValue = sqrtPriceU256  // sqrtPriceX96 in bits [0:159]
        
        // Add tick at bits [160:183]
        packedValue = packedValue + (tickU << 160)
        
        // Add observationIndex = 0 at bits [184:199] - already 0
        // Add observationCardinality = 1 at bits [200:215]
        packedValue = packedValue + (UInt256(1) << 200)
        
        // Add observationCardinalityNext = 1 at bits [216:231]
        packedValue = packedValue + (UInt256(1) << 216)
        
        // Add feeProtocol = 0 at bits [232:239] - already 0
        
        // Add unlocked = 1 (bool, 8 bits) at bits [240:247]
        packedValue = packedValue + (UInt256(1) << 240)
        
        // Convert to 32-byte hex string
        let packedBytes = packedValue.toBigEndianBytes()
        var slot0Bytes: [UInt8] = []
        
        // Pad to exactly 32 bytes
        var padCount = 32 - packedBytes.length
        while padCount > 0 {
            slot0Bytes.append(0)
            padCount = padCount - 1
        }
        slot0Bytes = slot0Bytes.concat(packedBytes)
        
        log("Packed value debug:")
        log("  sqrtPriceX96: \(sqrtPriceU256.toString())")
        log("  tick: \(targetTickAligned.toString())")
        log("  unlocked should be at bit 240")
        log("  packedValue: \(packedValue.toString())")
        
        let slot0Value = "0x".concat(String.encodeHex(slot0Bytes))
        log("slot0 packed value (32 bytes): \(slot0Value)")
        
        // ASSERTION: Verify slot0 is exactly 32 bytes
        assert(slot0Bytes.length == 32, message: "slot0 must be exactly 32 bytes")

        EVM.store(target: poolAddr, slot: "0x0", value: slot0Value)

        // Verify what we stored by reading it back
        let readBack = EVM.load(target: poolAddr, slot: "0x0")
        let readBackHex = "0x".concat(String.encodeHex(readBack))
        log("Read back from EVM.load: \(readBackHex)")
        
        // ASSERTION: Verify EVM.store/load round-trip works
        assert(readBackHex == slot0Value, message: "slot0 read-back mismatch - storage corruption!")
        assert(readBack.length == 32, message: "slot0 read-back wrong size")

        log("✓ slot0 set (sqrtPrice=\(targetSqrtPriceX96), tick=\(targetTickAligned.toString()), unlocked, observationCardinality=1)")
        
        // 5. Initialize observations[0] (REQUIRED or swaps will revert!)
        // Observations array structure (slot 8):
        // Solidity packs from LSB to MSB (right-to-left in big-endian hex):
        //   - blockTimestamp: uint32 (4 bytes) - lowest/rightmost
        //   - tickCumulative: int56 (7 bytes)
        //   - secondsPerLiquidityCumulativeX128: uint160 (20 bytes)
        //   - initialized: bool (1 byte) - highest/leftmost
        //
        // So in storage (big-endian), the 32-byte word is:
        //   [initialized(1)] [secondsPerLiquidity(20)] [tickCumulative(7)] [blockTimestamp(4)]
        
        // Get current block timestamp for observations[0]
        let currentTimestamp = UInt32(getCurrentBlock().timestamp)
        
        var obs0Bytes: [UInt8] = []
        
        // initialized = true (1 byte, highest/leftmost)
        obs0Bytes.append(1)
        
        // secondsPerLiquidityCumulativeX128 (uint160, 20 bytes) = 0
        var splCount = 0
        while splCount < 20 {
            obs0Bytes.append(0)
            splCount = splCount + 1
        }
        
        // tickCumulative (int56, 7 bytes) = 0
        var tcCount = 0
        while tcCount < 7 {
            obs0Bytes.append(0)
            tcCount = tcCount + 1
        }
        
        // blockTimestamp (uint32, big-endian, 4 bytes, lowest/rightmost)
        var ts = currentTimestamp
        var tsBytes: [UInt8] = []
        var tsi = 0
        while tsi < 4 {
            tsBytes.insert(at: 0, UInt8(ts % 256))
            ts = ts / 256
            tsi = tsi + 1
        }
        obs0Bytes.appendAll(tsBytes)
        
        // ASSERTION: Verify observations[0] is exactly 32 bytes
        assert(obs0Bytes.length == 32, message: "observations[0] must be exactly 32 bytes")
        assert(obs0Bytes[0] == 1, message: "initialized must be at byte 0 and = 1")
        
        let obs0Value = "0x".concat(String.encodeHex(obs0Bytes))
        EVM.store(target: poolAddr, slot: "0x8", value: obs0Value)
        log("✓ observations[0] initialized with timestamp=\(currentTimestamp.toString())")
        
        // 6. Set feeGrowthGlobal0X128 and feeGrowthGlobal1X128 (CRITICAL for swaps!)
        EVM.store(target: poolAddr, slot: "0x1", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        EVM.store(target: poolAddr, slot: "0x2", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        log("✓ feeGrowthGlobal set to 0")

        // 7. Set protocolFees (CRITICAL - this slot was missing!)
        // ProtocolFees struct: { uint128 token0; uint128 token1; }
        // Both should be 0 for a fresh pool
        EVM.store(target: poolAddr, slot: "0x3", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        log("✓ protocolFees set to 0")

        // 8. Set massive liquidity (MUST be exactly 32 bytes / 64 hex chars!)
        // 1e24 = 0xd3c21bcecceda1000000 (10 bytes) padded to 32 bytes
        let liquidityValue = "0x00000000000000000000000000000000000000000000d3c21bcecceda1000000"
        EVM.store(target: poolAddr, slot: "0x4", value: liquidityValue)
        log("✓ Global liquidity set to 1e24")
        
        // 9. Initialize boundary ticks with CORRECT storage layout
        // Tick.Info storage layout (multiple slots per tick):
        //   Slot 0: liquidityGross(128) + liquidityNet(128)
        //   Slot 1: feeGrowthOutside0X128(256)
        //   Slot 2: feeGrowthOutside1X128(256)
        //   Slot 3: tickCumulativeOutside(56) + secondsPerLiquidityOutsideX128(160) + secondsOutside(32) + initialized(8)
        
        // Lower tick
        let tickLowerSlot = computeMappingSlot([tickLower, UInt256(5)])  // ticks mapping at slot 5
        log("Tick lower slot: \(tickLowerSlot)")
        
        // Slot 0: liquidityGross=1e24 (lower 128 bits), liquidityNet=+1e24 (upper 128 bits)
        // CRITICAL: Struct is packed into ONE 32-byte slot (64 hex chars)
        // 1e24 padded to 16 bytes (uint128): 000000000000d3c21bcecceda1000000
        // Storage layout: [liquidityNet (upper 128)] [liquidityGross (lower 128)]
        let tickLowerData0 = "0x000000000000d3c21bcecceda1000000000000000000d3c21bcecceda1000000"
        
        // ASSERTION: Verify tick data is 32 bytes
        assert(tickLowerData0.length == 66, message: "Tick data must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: tickLowerSlot, value: tickLowerData0)
        
        // Calculate slot offsets by parsing the base slot and adding 1, 2, 3
        let tickLowerSlotBytes = tickLowerSlot.slice(from: 2, upTo: tickLowerSlot.length).decodeHex()
        var tickLowerSlotNum = UInt256(0)
        for byte in tickLowerSlotBytes {
            tickLowerSlotNum = tickLowerSlotNum * UInt256(256) + UInt256(byte)
        }
        
        // Slot 1: feeGrowthOutside0X128 = 0
        let tickLowerSlot1Bytes = (tickLowerSlotNum + UInt256(1)).toBigEndianBytes()
        var tickLowerSlot1Hex = "0x"
        var padCount1 = 32 - tickLowerSlot1Bytes.length
        while padCount1 > 0 {
            tickLowerSlot1Hex = tickLowerSlot1Hex.concat("00")
            padCount1 = padCount1 - 1
        }
        tickLowerSlot1Hex = tickLowerSlot1Hex.concat(String.encodeHex(tickLowerSlot1Bytes))
        EVM.store(target: poolAddr, slot: tickLowerSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        // Slot 2: feeGrowthOutside1X128 = 0
        let tickLowerSlot2Bytes = (tickLowerSlotNum + UInt256(2)).toBigEndianBytes()
        var tickLowerSlot2Hex = "0x"
        var padCount2 = 32 - tickLowerSlot2Bytes.length
        while padCount2 > 0 {
            tickLowerSlot2Hex = tickLowerSlot2Hex.concat("00")
            padCount2 = padCount2 - 1
        }
        tickLowerSlot2Hex = tickLowerSlot2Hex.concat(String.encodeHex(tickLowerSlot2Bytes))
        EVM.store(target: poolAddr, slot: tickLowerSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        // Slot 3: tickCumulativeOutside=0, secondsPerLiquidity=0, secondsOutside=0, initialized=true(0x01)
        let tickLowerSlot3Bytes = (tickLowerSlotNum + UInt256(3)).toBigEndianBytes()
        var tickLowerSlot3Hex = "0x"
        var padCount3 = 32 - tickLowerSlot3Bytes.length
        while padCount3 > 0 {
            tickLowerSlot3Hex = tickLowerSlot3Hex.concat("00")
            padCount3 = padCount3 - 1
        }
        tickLowerSlot3Hex = tickLowerSlot3Hex.concat(String.encodeHex(tickLowerSlot3Bytes))
        EVM.store(target: poolAddr, slot: tickLowerSlot3Hex, value: "0x0100000000000000000000000000000000000000000000000000000000000000")
        
        log("✓ Tick lower initialized (\(tickLower.toString()))")
        
        // Upper tick (liquidityNet is NEGATIVE for upper tick)
        let tickUpperSlot = computeMappingSlot([tickUpper, UInt256(5)])
        log("Tick upper slot: \(tickUpperSlot)")
        
        // Slot 0: liquidityGross=1e24 (lower 128 bits), liquidityNet=-1e24 (upper 128 bits, two's complement)
        // CRITICAL: Must be exactly 64 hex chars = 32 bytes
        // -1e24 in 128-bit two's complement: ffffffffffff2c3de43133125f000000 (32 chars = 16 bytes)
        // liquidityGross: 000000000000d3c21bcecceda1000000 (32 chars = 16 bytes)
        // Storage layout: [liquidityNet (upper 128)] [liquidityGross (lower 128)]
        let tickUpperData0 = "0xffffffffffff2c3de43133125f000000000000000000d3c21bcecceda1000000"
        
        // ASSERTION: Verify tick upper data is 32 bytes
        assert(tickUpperData0.length == 66, message: "Tick upper data must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: tickUpperSlot, value: tickUpperData0)
        
        let tickUpperSlotBytes = tickUpperSlot.slice(from: 2, upTo: tickUpperSlot.length).decodeHex()
        var tickUpperSlotNum = UInt256(0)
        for byte in tickUpperSlotBytes {
            tickUpperSlotNum = tickUpperSlotNum * UInt256(256) + UInt256(byte)
        }
        
        // Slot 1, 2, 3 same as lower
        let tickUpperSlot1Bytes = (tickUpperSlotNum + UInt256(1)).toBigEndianBytes()
        var tickUpperSlot1Hex = "0x"
        var padCount4 = 32 - tickUpperSlot1Bytes.length
        while padCount4 > 0 {
            tickUpperSlot1Hex = tickUpperSlot1Hex.concat("00")
            padCount4 = padCount4 - 1
        }
        tickUpperSlot1Hex = tickUpperSlot1Hex.concat(String.encodeHex(tickUpperSlot1Bytes))
        EVM.store(target: poolAddr, slot: tickUpperSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        let tickUpperSlot2Bytes = (tickUpperSlotNum + UInt256(2)).toBigEndianBytes()
        var tickUpperSlot2Hex = "0x"
        var padCount5 = 32 - tickUpperSlot2Bytes.length
        while padCount5 > 0 {
            tickUpperSlot2Hex = tickUpperSlot2Hex.concat("00")
            padCount5 = padCount5 - 1
        }
        tickUpperSlot2Hex = tickUpperSlot2Hex.concat(String.encodeHex(tickUpperSlot2Bytes))
        EVM.store(target: poolAddr, slot: tickUpperSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        let tickUpperSlot3Bytes = (tickUpperSlotNum + UInt256(3)).toBigEndianBytes()
        var tickUpperSlot3Hex = "0x"
        var padCount6 = 32 - tickUpperSlot3Bytes.length
        while padCount6 > 0 {
            tickUpperSlot3Hex = tickUpperSlot3Hex.concat("00")
            padCount6 = padCount6 - 1
        }
        tickUpperSlot3Hex = tickUpperSlot3Hex.concat(String.encodeHex(tickUpperSlot3Bytes))
        EVM.store(target: poolAddr, slot: tickUpperSlot3Hex, value: "0x0100000000000000000000000000000000000000000000000000000000000000")
        
        log("✓ Tick upper initialized (\(tickUpper.toString()))")
        
        // 10. Set tick bitmap (CRITICAL for tick crossing!)
        // Bitmap is at slot 6: mapping(int16 => uint256)
        // compressed tick = tick / tickSpacing
        // wordPos = int16(compressed >> 8)
        // bitPos = uint8(compressed & 255)
        
        let compressedLower = tickLower / tickSpacing
        let wordPosLower = compressedLower / Int256(256)
        // Fix: Cadence's modulo preserves sign, but we need 0-255
        var bitPosLower = compressedLower % Int256(256)
        if bitPosLower < Int256(0) {
            bitPosLower = bitPosLower + Int256(256)
        }
        
        let compressedUpper = tickUpper / tickSpacing  
        let wordPosUpper = compressedUpper / Int256(256)
        var bitPosUpper = compressedUpper % Int256(256)
        if bitPosUpper < Int256(0) {
            bitPosUpper = bitPosUpper + Int256(256)
        }
        
        log("Lower tick: compressed=\(compressedLower.toString()), wordPos=\(wordPosLower.toString()), bitPos=\(bitPosLower.toString())")
        log("Upper tick: compressed=\(compressedUpper.toString()), wordPos=\(wordPosUpper.toString()), bitPos=\(bitPosUpper.toString())")
        
        // Set bitmap for lower tick
        let bitmapLowerSlot = computeMappingSlot([wordPosLower, UInt256(6)])
        // Create a uint256 with bit at bitPosLower set
        // CRITICAL: In uint256, bit 0 is LSB (rightmost bit of rightmost byte)
        // So map bit position to byte index from the RIGHT
        
        // ASSERTION: Verify bitPos is valid
        assert(bitPosLower >= Int256(0) && bitPosLower < Int256(256), message: "bitPosLower must be 0-255, got \(bitPosLower.toString())")
        
        var bitmapLowerValue = "0x"
        var byteIdx = 0
        while byteIdx < 32 {
            // Map to byte from the right: bit 0-7 -> byte 31, bit 8-15 -> byte 30, etc.
            let byteIndexFromRight = Int(bitPosLower) / 8
            let targetByteIdx = 31 - byteIndexFromRight
            let bitInByte = Int(bitPosLower) % 8
            
            // ASSERTION: Verify byte index is valid
            assert(targetByteIdx >= 0 && targetByteIdx < 32, message: "targetByteIdx must be 0-31, got \(targetByteIdx)")
            
            var byteVal: UInt8 = 0
            if byteIdx == targetByteIdx {
                byteVal = UInt8(1) << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapLowerValue = bitmapLowerValue.concat(byteHex)
            byteIdx = byteIdx + 1
        }
        
        // ASSERTION: Verify bitmap value is correct length
        assert(bitmapLowerValue.length == 66, message: "bitmap must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: bitmapLowerSlot, value: bitmapLowerValue)
        log("✓ Bitmap set for lower tick")
        
        // Set bitmap for upper tick
        let bitmapUpperSlot = computeMappingSlot([wordPosUpper, UInt256(6)])
        // CRITICAL: In uint256, bit 0 is LSB (rightmost bit of rightmost byte)
        // So map bit position to byte index from the RIGHT
        
        // ASSERTION: Verify bitPos is valid
        assert(bitPosUpper >= Int256(0) && bitPosUpper < Int256(256), message: "bitPosUpper must be 0-255, got \(bitPosUpper.toString())")
        
        var bitmapUpperValue = "0x"
        byteIdx = 0
        while byteIdx < 32 {
            // Map to byte from the right: bit 0-7 -> byte 31, bit 8-15 -> byte 30, etc.
            let byteIndexFromRight = Int(bitPosUpper) / 8
            let targetByteIdx = 31 - byteIndexFromRight
            let bitInByte = Int(bitPosUpper) % 8
            
            // ASSERTION: Verify byte index is valid
            assert(targetByteIdx >= 0 && targetByteIdx < 32, message: "targetByteIdx must be 0-31, got \(targetByteIdx)")
            
            var byteVal: UInt8 = 0
            if byteIdx == targetByteIdx {
                byteVal = UInt8(1) << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapUpperValue = bitmapUpperValue.concat(byteHex)
            byteIdx = byteIdx + 1
        }
        
        // ASSERTION: Verify bitmap value is correct length
        assert(bitmapUpperValue.length == 66, message: "bitmap must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: bitmapUpperSlot, value: bitmapUpperValue)
        log("✓ Bitmap set for upper tick")

        // 11. CREATE POSITION (CRITICAL - without this, swaps fail!)
        // Positions mapping is at slot 7: mapping(bytes32 => Position.Info)
        // Position key = keccak256(abi.encodePacked(owner, tickLower, tickUpper))
        // We'll use the pool itself as the owner for simplicity

        log("\n=== CREATING POSITION ===")

        // Encode position key: keccak256(abi.encodePacked(pool, tickLower, tickUpper))
        // abi.encodePacked packs address(20 bytes) + int24(3 bytes) + int24(3 bytes) = 26 bytes
        var positionKeyData: [UInt8] = []

        // Add pool address (20 bytes)
        let poolBytes: [UInt8; 20] = poolAddr.bytes
        var i = 0
        while i < 20 {
            positionKeyData.append(poolBytes[i])
            i = i + 1
        }

        // Add tickLower (int24, 3 bytes, big-endian, two's complement)
        // CRITICAL: Must be EXACTLY 3 bytes for abi.encodePacked
        let tickLowerU256 = tickLower < Int256(0)
            ? (Int256(1) << 24) + tickLower  // Two's complement for negative
            : tickLower
        let tickLowerBytes = tickLowerU256.toBigEndianBytes()
        
        // Pad to exactly 3 bytes (left-pad with 0x00)
        var tickLower3Bytes: [UInt8] = []
        let tickLowerLen = tickLowerBytes.length
        if tickLowerLen < 3 {
            // Left-pad with zeros
            var padCount = 3 - tickLowerLen
            while padCount > 0 {
                tickLower3Bytes.append(0)
                padCount = padCount - 1
            }
            for byte in tickLowerBytes {
                tickLower3Bytes.append(byte)
            }
        } else {
            // Take last 3 bytes if longer
            tickLower3Bytes = [
                tickLowerBytes[tickLowerLen-3],
                tickLowerBytes[tickLowerLen-2],
                tickLowerBytes[tickLowerLen-1]
            ]
        }
        
        // ASSERTION: Verify tickLower is exactly 3 bytes
        assert(tickLower3Bytes.length == 3, message: "tickLower must be exactly 3 bytes for abi.encodePacked, got \(tickLower3Bytes.length)")
        
        for byte in tickLower3Bytes {
            positionKeyData.append(byte)
        }

        // Add tickUpper (int24, 3 bytes, big-endian, two's complement)
        // CRITICAL: Must be EXACTLY 3 bytes for abi.encodePacked
        let tickUpperU256 = tickUpper < Int256(0)
            ? (Int256(1) << 24) + tickUpper
            : tickUpper
        let tickUpperBytes = tickUpperU256.toBigEndianBytes()
        
        // Pad to exactly 3 bytes (left-pad with 0x00)
        var tickUpper3Bytes: [UInt8] = []
        let tickUpperLen = tickUpperBytes.length
        if tickUpperLen < 3 {
            // Left-pad with zeros
            var padCount = 3 - tickUpperLen
            while padCount > 0 {
                tickUpper3Bytes.append(0)
                padCount = padCount - 1
            }
            for byte in tickUpperBytes {
                tickUpper3Bytes.append(byte)
            }
        } else {
            // Take last 3 bytes if longer
            tickUpper3Bytes = [
                tickUpperBytes[tickUpperLen-3],
                tickUpperBytes[tickUpperLen-2],
                tickUpperBytes[tickUpperLen-1]
            ]
        }
        
        // ASSERTION: Verify tickUpper is exactly 3 bytes
        assert(tickUpper3Bytes.length == 3, message: "tickUpper must be exactly 3 bytes for abi.encodePacked, got \(tickUpper3Bytes.length)")
        
        for byte in tickUpper3Bytes {
            positionKeyData.append(byte)
        }
        
        // ASSERTION: Verify total position key data is exactly 26 bytes (20 + 3 + 3)
        assert(positionKeyData.length == 26, message: "Position key data must be 26 bytes (20 + 3 + 3), got \(positionKeyData.length)")

        let positionKeyHash = HashAlgorithm.KECCAK_256.hash(positionKeyData)
        let positionKeyHex = "0x".concat(String.encodeHex(positionKeyHash))
        log("Position key: \(positionKeyHex)")

        // Now compute storage slot: keccak256(positionKey . slot7)
        var positionSlotData: [UInt8] = []
        positionSlotData = positionSlotData.concat(positionKeyHash)

        // Add slot 7 as 32-byte value
        var slotBytes: [UInt8] = []
        var k = 0
        while k < 31 {
            slotBytes.append(0)
            k = k + 1
        }
        slotBytes.append(7)
        positionSlotData = positionSlotData.concat(slotBytes)
        
        // ASSERTION: Verify position slot data is 64 bytes (32 + 32)
        assert(positionSlotData.length == 64, message: "Position slot data must be 64 bytes (32 key + 32 slot), got \(positionSlotData.length)")

        let positionSlotHash = HashAlgorithm.KECCAK_256.hash(positionSlotData)
        let positionSlot = "0x".concat(String.encodeHex(positionSlotHash))
        log("Position storage slot: \(positionSlot)")

        // Position struct layout:
        //   Slot 0: liquidity (uint128, right-aligned)
        //   Slot 1: feeGrowthInside0LastX128 (uint256)
        //   Slot 2: feeGrowthInside1LastX128 (uint256)
        //   Slot 3: tokensOwed0 (uint128) + tokensOwed1 (uint128)

        // Set position liquidity = 1e24 (matching global liquidity)
        // CRITICAL: Must be exactly 32 bytes! Previous value was only 26 bytes.
        // uint128 liquidity is stored in the LOWER 128 bits (right-aligned)
        let positionLiquidityValue = "0x00000000000000000000000000000000000000000000d3c21bcecceda1000000"
        
        // ASSERTION: Verify position liquidity value is 32 bytes
        assert(positionLiquidityValue.length == 66, message: "Position liquidity must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: positionSlot, value: positionLiquidityValue)

        // Calculate slot+1, slot+2, slot+3
        let positionSlotBytes = positionSlotHash
        var positionSlotNum = UInt256(0)
        for byte in positionSlotBytes {
            positionSlotNum = positionSlotNum * UInt256(256) + UInt256(byte)
        }

        // Slot 1: feeGrowthInside0LastX128 = 0
        let positionSlot1Bytes = (positionSlotNum + UInt256(1)).toBigEndianBytes()
        var positionSlot1Hex = "0x"
        var posPadCount1 = 32 - positionSlot1Bytes.length
        while posPadCount1 > 0 {
            positionSlot1Hex = positionSlot1Hex.concat("00")
            posPadCount1 = posPadCount1 - 1
        }
        positionSlot1Hex = positionSlot1Hex.concat(String.encodeHex(positionSlot1Bytes))
        EVM.store(target: poolAddr, slot: positionSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 2: feeGrowthInside1LastX128 = 0
        let positionSlot2Bytes = (positionSlotNum + UInt256(2)).toBigEndianBytes()
        var positionSlot2Hex = "0x"
        var posPadCount2 = 32 - positionSlot2Bytes.length
        while posPadCount2 > 0 {
            positionSlot2Hex = positionSlot2Hex.concat("00")
            posPadCount2 = posPadCount2 - 1
        }
        positionSlot2Hex = positionSlot2Hex.concat(String.encodeHex(positionSlot2Bytes))
        EVM.store(target: poolAddr, slot: positionSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 3: tokensOwed0 = 0, tokensOwed1 = 0
        let positionSlot3Bytes = (positionSlotNum + UInt256(3)).toBigEndianBytes()
        var positionSlot3Hex = "0x"
        var posPadCount3 = 32 - positionSlot3Bytes.length
        while posPadCount3 > 0 {
            positionSlot3Hex = positionSlot3Hex.concat("00")
            posPadCount3 = posPadCount3 - 1
        }
        positionSlot3Hex = positionSlot3Hex.concat(String.encodeHex(positionSlot3Bytes))
        EVM.store(target: poolAddr, slot: positionSlot3Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        log("✓ Position created (owner=pool, liquidity=1e24)")

        // 12. Fund pool with massive token balances using caller-specified slots
        let hugeBalance = "0x000000000000000000000000af298d050e4395d69670b12b7f41000000000000" // 1e48
        
        // Set token0 balance at the specified slot
        let token0BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token0BalanceSlot)
        EVM.store(target: token0, slot: token0BalanceSlotComputed, value: hugeBalance)
        log("✓ Token0 balance funded at slot \(token0BalanceSlot.toString())")
        
        // Set token1 balance at the specified slot
        let token1BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token1BalanceSlot)
        EVM.store(target: token1, slot: token1BalanceSlotComputed, value: hugeBalance)
        log("✓ Token1 balance funded at slot \(token1BalanceSlot.toString())")
        
        log("\n✓✓✓ POOL FULLY SEEDED WITH STRUCTURALLY VALID V3 STATE ✓✓✓")
        log("  - slot0: initialized, unlocked, price set to target")
        log("  - observations[0]: initialized")
        log("  - feeGrowthGlobal0X128 & feeGrowthGlobal1X128: set to 0")
        log("  - protocolFees: set to 0 (FIXED - this was missing!)")
        log("  - liquidity: 1e24")
        log("  - ticks: both boundaries initialized with correct liquidityGross/Net")
        log("  - bitmap: both tick bits set correctly")
        log("  - position: created with 1e24 liquidity (owner=pool)")
        log("  - token balances: massive reserves already set during initial pool creation")
        log("\nNote: Token balances are set at passed slots (0 for MOET, 1 for PYUSD0/WFLOW, 12 for FUSDEV) during initial creation")
        log("      These balances persist across price updates and don't need to match the price")
    }
}
