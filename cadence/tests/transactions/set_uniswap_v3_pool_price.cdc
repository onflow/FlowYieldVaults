import EVM from "MockEVM"

// Helper: Compute Solidity mapping storage slot
access(all) fun computeMappingSlot(_ values: [AnyStruct]): String {
    let encoded = EVM.encodeABI(values)
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)
    return "0x\(String.encodeHex(hashBytes))"
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
        
        // Get pool address from factory
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
        
        // Check pool exists
        var isZero = true
        for byte in poolAddr.bytes {
            if byte != 0 {
                isZero = false
                break
            }
        }
        assert(!isZero, message: "Pool does not exist - create it first")
        
        // Read pool parameters (tickSpacing is CRITICAL)
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
        
        // Round targetTick to nearest tickSpacing multiple
        // NOTE: In real Uniswap V3, slot0.tick doesn't need to be on tickSpacing boundaries
        // (only initialized ticks with liquidity do). However, rounding here ensures consistency
        // and avoids potential edge cases. The price difference is minimal (e.g., ~0.16% for tick 
        // 6931→6900). We may revisit this if exact prices become critical.
        // TODO: Consider passing unrounded tick to slot0 if precision matters
        let targetTickAligned = (targetTick / tickSpacing) * tickSpacing
        
        // Calculate full-range ticks (MUST be multiples of tickSpacing!)
        let tickLower = (-887272 as Int256) / tickSpacing * tickSpacing
        let tickUpper = (887272 as Int256) / tickSpacing * tickSpacing
        
        // Set slot0 with target price
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
        let tickMask = UInt256(((1 as Int256) << 24) - 1)  // 0xFFFFFF
        let tickU = UInt256(
            targetTickAligned < 0 
                ? ((1 as Int256) << 24) + targetTickAligned  // Two's complement for negative
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
        packedValue = packedValue + (1 << 200)
        
        // Add observationCardinalityNext = 1 at bits [216:231]
        packedValue = packedValue + (1 << 216)
        
        // Add feeProtocol = 0 at bits [232:239] - already 0
        
        // Add unlocked = 1 (bool, 8 bits) at bits [240:247]
        packedValue = packedValue + (1 << 240)
        
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
        
        let slot0Value = "0x\(String.encodeHex(slot0Bytes))"
        
        // ASSERTION: Verify slot0 is exactly 32 bytes
        assert(slot0Bytes.length == 32, message: "slot0 must be exactly 32 bytes")

        EVM.store(target: poolAddr, slot: "0x0", value: slot0Value)

        // Verify what we stored by reading it back
        let readBack = EVM.load(target: poolAddr, slot: "0x0")
        let readBackHex = "0x\(String.encodeHex(readBack))"
        
        // ASSERTION: Verify EVM.store/load round-trip works
        assert(readBackHex == slot0Value, message: "slot0 read-back mismatch - storage corruption!")
        assert(readBack.length == 32, message: "slot0 read-back wrong size")

        // Initialize observations[0] (REQUIRED or swaps will revert!)
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
        obs0Bytes.appendAll([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
        
        // tickCumulative (int56, 7 bytes) = 0
        obs0Bytes.appendAll([0,0,0,0,0,0,0])
        
        // blockTimestamp (uint32, big-endian, 4 bytes, lowest/rightmost)
        let tsBytes = currentTimestamp.toBigEndianBytes()
        obs0Bytes.appendAll(tsBytes)
        
        // ASSERTION: Verify observations[0] is exactly 32 bytes
        assert(obs0Bytes.length == 32, message: "observations[0] must be exactly 32 bytes")
        assert(obs0Bytes[0] == 1, message: "initialized must be at byte 0 and = 1")
        
        let obs0Value = "0x\(String.encodeHex(obs0Bytes))"
        EVM.store(target: poolAddr, slot: "0x8", value: obs0Value)
        
        // Set feeGrowthGlobal0X128 and feeGrowthGlobal1X128 (CRITICAL for swaps!)
        EVM.store(target: poolAddr, slot: "0x1", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        EVM.store(target: poolAddr, slot: "0x2", value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Set protocolFees (CRITICAL)
        EVM.store(target: poolAddr, slot: "0x3", value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Set massive liquidity
        let liquidityValue = "0x00000000000000000000000000000000000000000000d3c21bcecceda1000000"
        EVM.store(target: poolAddr, slot: "0x4", value: liquidityValue)
        
        // Initialize boundary ticks with CORRECT storage layout
        
        // Lower tick
        let tickLowerSlot = computeMappingSlot([tickLower, 5])
        
        // Slot 0: liquidityGross=1e24 (lower 128 bits), liquidityNet=+1e24 (upper 128 bits)
        let tickLowerData0 = "0x000000000000d3c21bcecceda1000000000000000000d3c21bcecceda1000000"
        
        // ASSERTION: Verify tick data is 32 bytes
        assert(tickLowerData0.length == 66, message: "Tick data must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: tickLowerSlot, value: tickLowerData0)
        
        // Calculate slot offsets by parsing the base slot and adding 1, 2, 3
        let tickLowerSlotBytes = tickLowerSlot.slice(from: 2, upTo: tickLowerSlot.length).decodeHex()
        var tickLowerSlotNum = 0 as UInt256
        for byte in tickLowerSlotBytes {
            tickLowerSlotNum = tickLowerSlotNum * 256 + UInt256(byte)
        }
        
        // Slot 1: feeGrowthOutside0X128 = 0
        let tickLowerSlot1Bytes = (tickLowerSlotNum + 1).toBigEndianBytes()
        var tickLowerSlot1Hex = "0x"
        var padCount1 = 32 - tickLowerSlot1Bytes.length
        while padCount1 > 0 {
            tickLowerSlot1Hex = "\(tickLowerSlot1Hex)00"
            padCount1 = padCount1 - 1
        }
        tickLowerSlot1Hex = "\(tickLowerSlot1Hex)\(String.encodeHex(tickLowerSlot1Bytes))"
        EVM.store(target: poolAddr, slot: tickLowerSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        // Slot 2: feeGrowthOutside1X128 = 0
        let tickLowerSlot2Bytes = (tickLowerSlotNum + 2).toBigEndianBytes()
        var tickLowerSlot2Hex = "0x"
        var padCount2 = 32 - tickLowerSlot2Bytes.length
        while padCount2 > 0 {
            tickLowerSlot2Hex = "\(tickLowerSlot2Hex)00"
            padCount2 = padCount2 - 1
        }
        tickLowerSlot2Hex = "\(tickLowerSlot2Hex)\(String.encodeHex(tickLowerSlot2Bytes))"
        EVM.store(target: poolAddr, slot: tickLowerSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        // Slot 3: tickCumulativeOutside=0, secondsPerLiquidity=0, secondsOutside=0, initialized=true(0x01)
        let tickLowerSlot3Bytes = (tickLowerSlotNum + 3).toBigEndianBytes()
        var tickLowerSlot3Hex = "0x"
        var padCount3 = 32 - tickLowerSlot3Bytes.length
        while padCount3 > 0 {
            tickLowerSlot3Hex = "\(tickLowerSlot3Hex)00"
            padCount3 = padCount3 - 1
        }
        tickLowerSlot3Hex = "\(tickLowerSlot3Hex)\(String.encodeHex(tickLowerSlot3Bytes))"
        EVM.store(target: poolAddr, slot: tickLowerSlot3Hex, value: "0x0100000000000000000000000000000000000000000000000000000000000000")
        
        // Upper tick (liquidityNet is NEGATIVE for upper tick)
        let tickUpperSlot = computeMappingSlot([tickUpper, 5])
        
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
        var tickUpperSlotNum = 0 as UInt256
        for byte in tickUpperSlotBytes {
            tickUpperSlotNum = tickUpperSlotNum * 256 + UInt256(byte)
        }
        
        // Slot 1, 2, 3 same as lower
        let tickUpperSlot1Bytes = (tickUpperSlotNum + 1).toBigEndianBytes()
        var tickUpperSlot1Hex = "0x"
        var padCount4 = 32 - tickUpperSlot1Bytes.length
        while padCount4 > 0 {
            tickUpperSlot1Hex = "\(tickUpperSlot1Hex)00"
            padCount4 = padCount4 - 1
        }
        tickUpperSlot1Hex = "\(tickUpperSlot1Hex)\(String.encodeHex(tickUpperSlot1Bytes))"
        EVM.store(target: poolAddr, slot: tickUpperSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        let tickUpperSlot2Bytes = (tickUpperSlotNum + 2).toBigEndianBytes()
        var tickUpperSlot2Hex = "0x"
        var padCount5 = 32 - tickUpperSlot2Bytes.length
        while padCount5 > 0 {
            tickUpperSlot2Hex = "\(tickUpperSlot2Hex)00"
            padCount5 = padCount5 - 1
        }
        tickUpperSlot2Hex = "\(tickUpperSlot2Hex)\(String.encodeHex(tickUpperSlot2Bytes))"
        EVM.store(target: poolAddr, slot: tickUpperSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        
        let tickUpperSlot3Bytes = (tickUpperSlotNum + 3).toBigEndianBytes()
        var tickUpperSlot3Hex = "0x"
        var padCount6 = 32 - tickUpperSlot3Bytes.length
        while padCount6 > 0 {
            tickUpperSlot3Hex = "\(tickUpperSlot3Hex)00"
            padCount6 = padCount6 - 1
        }
        tickUpperSlot3Hex = "\(tickUpperSlot3Hex)\(String.encodeHex(tickUpperSlot3Bytes))"
        EVM.store(target: poolAddr, slot: tickUpperSlot3Hex, value: "0x0100000000000000000000000000000000000000000000000000000000000000")
        
        // Set tick bitmap (CRITICAL for tick crossing!)
        
        let compressedLower = tickLower / tickSpacing
        let wordPosLower = compressedLower / 256
        var bitPosLower = compressedLower % 256
        if bitPosLower < 0 {
            bitPosLower = bitPosLower + 256
        }
        
        let compressedUpper = tickUpper / tickSpacing  
        let wordPosUpper = compressedUpper / 256
        var bitPosUpper = compressedUpper % 256
        if bitPosUpper < 0 {
            bitPosUpper = bitPosUpper + 256
        }
        
        // Set bitmap for lower tick
        let bitmapLowerSlot = computeMappingSlot([wordPosLower, 6])
        
        // ASSERTION: Verify bitPos is valid
        assert(bitPosLower >= 0 && bitPosLower < 256, message: "bitPosLower must be 0-255, got \(bitPosLower.toString())")
        
        var bitmapLowerValue = "0x"
        var byteIdx = 0
        while byteIdx < 32 {
            let byteIndexFromRight = Int(bitPosLower) / 8
            let targetByteIdx = 31 - byteIndexFromRight
            let bitInByte = Int(bitPosLower) % 8
            
            // ASSERTION: Verify byte index is valid
            assert(targetByteIdx >= 0 && targetByteIdx < 32, message: "targetByteIdx must be 0-31, got \(targetByteIdx)")
            
            var byteVal: UInt8 = 0
            if byteIdx == targetByteIdx {
                byteVal = 1 << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapLowerValue = "\(bitmapLowerValue)\(byteHex)"
            byteIdx = byteIdx + 1
        }
        
        // ASSERTION: Verify bitmap value is correct length
        assert(bitmapLowerValue.length == 66, message: "bitmap must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: bitmapLowerSlot, value: bitmapLowerValue)
        
        // Set bitmap for upper tick
        let bitmapUpperSlot = computeMappingSlot([wordPosUpper, UInt256(6)])
        
        // ASSERTION: Verify bitPos is valid
        assert(bitPosUpper >= 0 && bitPosUpper < 256, message: "bitPosUpper must be 0-255, got \(bitPosUpper.toString())")
        
        var bitmapUpperValue = "0x"
        byteIdx = 0
        while byteIdx < 32 {
            let byteIndexFromRight = Int(bitPosUpper) / 8
            let targetByteIdx = 31 - byteIndexFromRight
            let bitInByte = Int(bitPosUpper) % 8
            
            // ASSERTION: Verify byte index is valid
            assert(targetByteIdx >= 0 && targetByteIdx < 32, message: "targetByteIdx must be 0-31, got \(targetByteIdx)")
            
            var byteVal: UInt8 = 0
            if byteIdx == targetByteIdx {
                byteVal = 1 << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapUpperValue = "\(bitmapUpperValue)\(byteHex)"
            byteIdx = byteIdx + 1
        }
        
        // ASSERTION: Verify bitmap value is correct length
        assert(bitmapUpperValue.length == 66, message: "bitmap must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: bitmapUpperSlot, value: bitmapUpperValue)

        // CREATE POSITION (CRITICAL)

        var positionKeyData: [UInt8] = []

        // Add pool address (20 bytes)
        positionKeyData.appendAll(poolAddr.bytes.toVariableSized())

        // Add tickLower (int24, 3 bytes, big-endian, two's complement)
        let tickLowerU256 = tickLower < 0
            ? ((1 as Int256) << 24) + tickLower  // Two's complement for negative
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
        let tickUpperU256 = tickUpper < 0
            ? ((1 as Int256) << 24) + tickUpper
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
        assert(positionKeyData.length == 26, message: "Position key data must be 26 bytes (20 + 3 + 3), got \(positionKeyData.length.toString())")

        let positionKeyHash = HashAlgorithm.KECCAK_256.hash(positionKeyData)
        let positionKeyHex = "0x".concat(String.encodeHex(positionKeyHash))

        // Now compute storage slot: keccak256(positionKey . slot7)
        var positionSlotData: [UInt8] = []
        positionSlotData = positionSlotData.concat(positionKeyHash)

        // Add slot 7 as 32-byte value (31 zeros + 7)
        var slotBytes: [UInt8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7]
        positionSlotData = positionSlotData.concat(slotBytes)
        
        // ASSERTION: Verify position slot data is 64 bytes (32 + 32)
        assert(positionSlotData.length == 64, message: "Position slot data must be 64 bytes (32 key + 32 slot), got \(positionSlotData.length)")

        let positionSlotHash = HashAlgorithm.KECCAK_256.hash(positionSlotData)
        let positionSlot = "0x\(String.encodeHex(positionSlotHash))"

        // Set position liquidity = 1e24 (matching global liquidity)
        let positionLiquidityValue = "0x00000000000000000000000000000000000000000000d3c21bcecceda1000000"
        
        // ASSERTION: Verify position liquidity value is 32 bytes
        assert(positionLiquidityValue.length == 66, message: "Position liquidity must be 0x + 64 hex chars = 66 chars total")
        
        EVM.store(target: poolAddr, slot: positionSlot, value: positionLiquidityValue)

        // Calculate slot+1, slot+2, slot+3
        let positionSlotBytes = positionSlotHash
        var positionSlotNum = 0 as UInt256
        for byte in positionSlotBytes {
            positionSlotNum = positionSlotNum * 256 + UInt256(byte)
        }

        // Slot 1: feeGrowthInside0LastX128 = 0
        let positionSlot1Bytes = (positionSlotNum + 1).toBigEndianBytes()
        var positionSlot1Hex = "0x"
        var posPadCount1 = 32 - positionSlot1Bytes.length
        while posPadCount1 > 0 {
            positionSlot1Hex = "\(positionSlot1Hex)00"
            posPadCount1 = posPadCount1 - 1
        }
        positionSlot1Hex = "\(positionSlot1Hex)\(String.encodeHex(positionSlot1Bytes))"
        EVM.store(target: poolAddr, slot: positionSlot1Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 2: feeGrowthInside1LastX128 = 0
        let positionSlot2Bytes = (positionSlotNum + 2).toBigEndianBytes()
        var positionSlot2Hex = "0x"
        var posPadCount2 = 32 - positionSlot2Bytes.length
        while posPadCount2 > 0 {
            positionSlot2Hex = "\(positionSlot2Hex)00"
            posPadCount2 = posPadCount2 - 1
        }
        positionSlot2Hex = "\(positionSlot2Hex)\(String.encodeHex(positionSlot2Bytes))"
        EVM.store(target: poolAddr, slot: positionSlot2Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 3: tokensOwed0 = 0, tokensOwed1 = 0
        let positionSlot3Bytes = (positionSlotNum + 3).toBigEndianBytes()
        var positionSlot3Hex = "0x"
        var posPadCount3 = 32 - positionSlot3Bytes.length
        while posPadCount3 > 0 {
            positionSlot3Hex = "\(positionSlot3Hex)00"
            posPadCount3 = posPadCount3 - 1
        }
        positionSlot3Hex = "\(positionSlot3Hex)\(String.encodeHex(positionSlot3Bytes))"
        EVM.store(target: poolAddr, slot: positionSlot3Hex, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Fund pool with massive token balances
        let hugeBalance = "0x000000000000000000000000af298d050e4395d69670b12b7f41000000000000"
        
        // Set token0 balance
        let token0BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token0BalanceSlot)
        EVM.store(target: token0, slot: token0BalanceSlotComputed, value: hugeBalance)
        
        // Set token1 balance
        let token1BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token1BalanceSlot)
        EVM.store(target: token1, slot: token1BalanceSlotComputed, value: hugeBalance)
    }
}
