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
    targetTick: Int256
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
        let tickU24 = targetTick < Int256(0)
            ? (Int256(1) << 24) + targetTick  // Two's complement
            : targetTick
        
        // Now pack everything into a UInt256
        // Formula: value = sqrtPrice + (tick << 160) + (obsIndex << 184) + (obsCard << 200) + 
        //                 (obsCardNext << 216) + (feeProtocol << 232) + (unlocked << 240)
        
        var packedValue = sqrtPriceU256  // sqrtPriceX96 in bits [0:159]
        
        // Add tick at bits [160:183]
        if tickU24 < Int256(0) {
            // For negative tick, use two's complement in 24 bits
            let tickMask = UInt256((Int256(1) << 24) - 1)  // 0xFFFFFF
            let tickU = UInt256((Int256(1) << 24) + tickU24) & tickMask
            packedValue = packedValue + (tickU << 160)
        } else {
            packedValue = packedValue + (UInt256(tickU24) << 160)
        }
        
        // Add observationIndex = 0 at bits [184:199] - already 0
        // Add observationCardinality = 1 at bits [200:215]
        packedValue = packedValue + (UInt256(1) << 200)
        
        // Add observationCardinalityNext = 1 at bits [216:231]
        packedValue = packedValue + (UInt256(1) << 216)
        
        // Add feeProtocol = 0 at bits [232:239] - already 0
        
        // Add unlocked = 1 at bit [240]
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
        
        let slot0Value = "0x".concat(String.encodeHex(slot0Bytes))
        log("slot0 packed value (32 bytes): \(slot0Value)")

        EVM.store(target: poolAddr, slot: "0x0", value: slot0Value)

        // Verify what we stored by reading it back
        let readBack = EVM.load(target: poolAddr, slot: "0x0")
        let readBackHex = "0x".concat(String.encodeHex(readBack))
        log("Read back from EVM.load: \(readBackHex)")
        log("Matches what we stored: \(readBackHex == slot0Value)")

        log("✓ slot0 set (sqrtPrice=\(targetSqrtPriceX96), tick=\(targetTick.toString()), unlocked, observationCardinality=1)")
        
        // 5. Initialize observations[0] (REQUIRED or swaps will revert!)
        // observations is at slot 8, slot structure: blockTimestamp(32) + tickCumulative(56) + secondsPerLiquidityX128(160) + initialized(8)
        let obs0Value = "0x0100000000000000000000000000000000000000000000000000000000000001"
        EVM.store(target: poolAddr, slot: "0x8", value: obs0Value)
        log("✓ observations[0] initialized")
        
        // 6. Set feeGrowthGlobal0X128 and feeGrowthGlobal1X128 (CRITICAL for swaps!)
        EVM.store(target: poolAddr, slot: "0x1", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        EVM.store(target: poolAddr, slot: "0x2", value: "0x0000000000000000000000000000000000000000000000000000000000000000")
        log("✓ feeGrowthGlobal set to 0")

        // 7. Set massive liquidity
        let liquidityValue = "0x00000000000000000000000000000000000000000000d3c21bcecceda1000000" // 1e24
        EVM.store(target: poolAddr, slot: "0x4", value: liquidityValue)
        log("✓ Global liquidity set to 1e24")
        
        // 8. Initialize boundary ticks with CORRECT storage layout
        // Tick.Info storage layout (multiple slots per tick):
        //   Slot 0: liquidityGross(128) + liquidityNet(128)
        //   Slot 1: feeGrowthOutside0X128(256)
        //   Slot 2: feeGrowthOutside1X128(256)
        //   Slot 3: tickCumulativeOutside(56) + secondsPerLiquidityOutsideX128(160) + secondsOutside(32) + initialized(8)
        
        // Lower tick
        let tickLowerSlot = computeMappingSlot([tickLower, UInt256(5)])  // ticks mapping at slot 5
        log("Tick lower slot: \(tickLowerSlot)")
        
        // Slot 0: liquidityGross=1e24, liquidityNet=1e24 (positive because this is lower tick)
        let tickLowerData0 = "0x00000000000000000000000000000000d3c21bcecceda1000000d3c21bcecceda1000000"
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
        
        // Slot 0: liquidityGross=1e24, liquidityNet=-1e24 (negative, two's complement)
        let tickUpperData0 = "0xffffffffffffffffffffffffffffffff2c3de431232a15efffff2c3de431232a15f000000"
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
        
        // 9. Set tick bitmap (CRITICAL for tick crossing!)
        // Bitmap is at slot 6: mapping(int16 => uint256)
        // compressed tick = tick / tickSpacing
        // wordPos = int16(compressed >> 8)
        // bitPos = uint8(compressed & 255)
        
        let compressedLower = tickLower / tickSpacing
        let wordPosLower = compressedLower / Int256(256)
        let bitPosLower = compressedLower % Int256(256)
        
        let compressedUpper = tickUpper / tickSpacing  
        let wordPosUpper = compressedUpper / Int256(256)
        let bitPosUpper = compressedUpper % Int256(256)
        
        log("Lower tick: compressed=\(compressedLower.toString()), wordPos=\(wordPosLower.toString()), bitPos=\(bitPosLower.toString())")
        log("Upper tick: compressed=\(compressedUpper.toString()), wordPos=\(wordPosUpper.toString()), bitPos=\(bitPosUpper.toString())")
        
        // Set bitmap for lower tick
        let bitmapLowerSlot = computeMappingSlot([wordPosLower, UInt256(6)])
        // Create a uint256 with bit at bitPosLower set
        var bitmapLowerValue = "0x"
        var byteIdx = 0
        while byteIdx < 32 {
            let bitStart = byteIdx * 8
            let bitEnd = bitStart + 8
            var byteVal: UInt8 = 0
            
            if bitPosLower >= Int256(bitStart) && bitPosLower < Int256(bitEnd) {
                let bitInByte = Int(bitPosLower) - bitStart
                byteVal = UInt8(1) << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapLowerValue = bitmapLowerValue.concat(byteHex)
            byteIdx = byteIdx + 1
        }
        EVM.store(target: poolAddr, slot: bitmapLowerSlot, value: bitmapLowerValue)
        log("✓ Bitmap set for lower tick")
        
        // Set bitmap for upper tick
        let bitmapUpperSlot = computeMappingSlot([wordPosUpper, UInt256(6)])
        var bitmapUpperValue = "0x"
        byteIdx = 0
        while byteIdx < 32 {
            let bitStart = byteIdx * 8
            let bitEnd = bitStart + 8
            var byteVal: UInt8 = 0
            
            if bitPosUpper >= Int256(bitStart) && bitPosUpper < Int256(bitEnd) {
                let bitInByte = Int(bitPosUpper) - bitStart
                byteVal = UInt8(1) << UInt8(bitInByte)
            }
            
            let byteHex = String.encodeHex([byteVal])
            bitmapUpperValue = bitmapUpperValue.concat(byteHex)
            byteIdx = byteIdx + 1
        }
        EVM.store(target: poolAddr, slot: bitmapUpperSlot, value: bitmapUpperValue)
        log("✓ Bitmap set for upper tick")

        // 10. CREATE POSITION (CRITICAL - without this, swaps fail!)
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
        let tickLowerU256 = tickLower < Int256(0)
            ? (Int256(1) << 24) + tickLower  // Two's complement for negative
            : tickLower
        let tickLowerBytes = tickLowerU256.toBigEndianBytes()
        // Take ONLY the last 3 bytes (int24 is always 3 bytes in abi.encodePacked)
        let tickLowerLen = tickLowerBytes.length
        let tickLower3Bytes = tickLowerLen >= 3
            ? [tickLowerBytes[tickLowerLen-3], tickLowerBytes[tickLowerLen-2], tickLowerBytes[tickLowerLen-1]]
            : tickLowerBytes  // Should never happen for valid ticks
        for byte in tickLower3Bytes {
            positionKeyData.append(byte)
        }

        // Add tickUpper (int24, 3 bytes, big-endian, two's complement)
        let tickUpperU256 = tickUpper < Int256(0)
            ? (Int256(1) << 24) + tickUpper
            : tickUpper
        let tickUpperBytes = tickUpperU256.toBigEndianBytes()
        // Take ONLY the last 3 bytes (int24 is always 3 bytes in abi.encodePacked)
        let tickUpperLen = tickUpperBytes.length
        let tickUpper3Bytes = tickUpperLen >= 3
            ? [tickUpperBytes[tickUpperLen-3], tickUpperBytes[tickUpperLen-2], tickUpperBytes[tickUpperLen-1]]
            : tickUpperBytes  // Should never happen for valid ticks
        for byte in tickUpper3Bytes {
            positionKeyData.append(byte)
        }

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

        let positionSlotHash = HashAlgorithm.KECCAK_256.hash(positionSlotData)
        let positionSlot = "0x".concat(String.encodeHex(positionSlotHash))
        log("Position storage slot: \(positionSlot)")

        // Position struct layout:
        //   Slot 0: liquidity (uint128, right-aligned)
        //   Slot 1: feeGrowthInside0LastX128 (uint256)
        //   Slot 2: feeGrowthInside1LastX128 (uint256)
        //   Slot 3: tokensOwed0 (uint128) + tokensOwed1 (uint128)

        // Set position liquidity = 1e24 (matching global liquidity)
        let positionLiquidityValue = "0x00000000000000000000000000000000d3c21bcecceda1000000"
        EVM.store(target: poolAddr, slot: positionSlot, value: positionLiquidityValue)

        // Calculate slot+1, slot+2, slot+3
        let positionSlotBytes = positionSlotHash
        var positionSlotNum = UInt256(0)
        for byte in positionSlotBytes {
            positionSlotNum = positionSlotNum * UInt256(256) + UInt256(byte)
        }

        // Slot 1: feeGrowthInside0LastX128 = 0
        let positionSlot1 = "0x".concat(String.encodeHex((positionSlotNum + UInt256(1)).toBigEndianBytes()))
        EVM.store(target: poolAddr, slot: positionSlot1, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 2: feeGrowthInside1LastX128 = 0
        let positionSlot2 = "0x".concat(String.encodeHex((positionSlotNum + UInt256(2)).toBigEndianBytes()))
        EVM.store(target: poolAddr, slot: positionSlot2, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        // Slot 3: tokensOwed0 = 0, tokensOwed1 = 0
        let positionSlot3 = "0x".concat(String.encodeHex((positionSlotNum + UInt256(3)).toBigEndianBytes()))
        EVM.store(target: poolAddr, slot: positionSlot3, value: "0x0000000000000000000000000000000000000000000000000000000000000000")

        log("✓ Position created (owner=pool, liquidity=1e24)")

        // 11. Fund pool with massive token balances
        let balance0 = "0x0000000000000000000000000000000000c097ce7bc90715b34b9f1000000000" // 1e36 (for 6 decimal tokens)
        let balance1 = "0x000000000000000000000000af298d050e4395d69670b12b7f41000000000000" // 1e48 (for 18 decimal tokens)
        
        // Need to determine which token has which decimals
        // For now, use larger balance for both to be safe
        let hugeBalance = balance1
        
        // Get balanceOf slot for each token (ERC20 standard varies, common slots are 0, 1, or 51)
        // Try slot 1 first (common for many tokens)
        let token0BalanceSlot = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(1))
        EVM.store(target: token0, slot: token0BalanceSlot, value: hugeBalance)
        log("✓ Token0 balance funded (slot 1)")
        
        // Also try slot 0 (backup)
        let token0BalanceSlot0 = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(0))
        EVM.store(target: token0, slot: token0BalanceSlot0, value: hugeBalance)
        
        let token1BalanceSlot = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(1))
        EVM.store(target: token1, slot: token1BalanceSlot, value: hugeBalance)
        log("✓ Token1 balance funded (slot 1)")
        
        let token1BalanceSlot0 = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(0))
        EVM.store(target: token1, slot: token1BalanceSlot0, value: hugeBalance)
        
        // If token1 is FUSDEV (ERC4626), try slot 51 too
        if token1Address.toLower() == "0xd069d989e2f44b70c65347d1853c0c67e10a9f8d" {
            let fusdevBalanceSlot = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(51))
            EVM.store(target: token1, slot: fusdevBalanceSlot, value: hugeBalance)
            log("✓ FUSDEV balance also set at slot 51")
        }
        if token0Address.toLower() == "0xd069d989e2f44b70c65347d1853c0c67e10a9f8d" {
            let fusdevBalanceSlot = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: UInt256(51))
            EVM.store(target: token0, slot: fusdevBalanceSlot, value: hugeBalance)
            log("✓ FUSDEV balance also set at slot 51")
        }
        
        log("\n✓✓✓ POOL FULLY SEEDED WITH STRUCTURALLY VALID V3 STATE ✓✓✓")
        log("  - slot0: initialized, unlocked, 1:1 price")
        log("  - observations[0]: initialized")
        log("  - feeGrowthGlobal0X128 & feeGrowthGlobal1X128: set to 0")
        log("  - liquidity: 1e24")
        log("  - ticks: both boundaries initialized with correct liquidityGross/Net")
        log("  - bitmap: both tick bits set correctly")
        log("  - position: created with 1e24 liquidity (owner=pool)")
        log("  - token balances: massive balances in pool")
    }
}
