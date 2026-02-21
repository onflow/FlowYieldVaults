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
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix64,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256
) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    prepare(signer: auth(Storage) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA")
    }

    execute {
        // Sort tokens (Uniswap V3 requires token0 < token1)
        let factory = EVM.addressFromString(factoryAddress)
        let token0 = EVM.addressFromString(tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress)
        let token1 = EVM.addressFromString(tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress)
        let token0BalanceSlot = tokenAAddress < tokenBAddress ? tokenABalanceSlot : tokenBBalanceSlot
        let token1BalanceSlot = tokenAAddress < tokenBAddress ? tokenBBalanceSlot : tokenABalanceSlot
        
        let poolPriceHuman = tokenAAddress < tokenBAddress ? priceTokenBPerTokenA : 1.0 / priceTokenBPerTokenA
        
        // Read decimals from EVM
        let token0Decimals = getTokenDecimals(evmContractAddress: token0)
        let token1Decimals = getTokenDecimals(evmContractAddress: token1)
        let decOffset = Int(token1Decimals) - Int(token0Decimals)
        
        // Calculate tick from decimal-adjusted price, then derive sqrtPriceX96 from tick
        // This ensures they satisfy Uniswap's invariant: sqrtPriceX96 = getSqrtRatioAtTick(tick)
        let targetTick = calculateTick(price: poolPriceHuman, decimalOffset: decOffset)
        var targetSqrtPriceX96 = calculateSqrtPriceX96FromTick(tick: targetTick)
        
        // First check if pool already exists
        var getPoolCalldata = EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)",
            [token0, token1, UInt256(fee)]
        )
        var getPoolResult = self.coa.dryCall(
            to: factory,
            data: getPoolCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        
        assert(getPoolResult.status == EVM.Status.successful, message: "Failed to query pool from factory")
        
        // Decode pool address
        var poolAddr = (EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: getPoolResult.data)[0] as! EVM.EVMAddress)
        let zeroAddress = EVM.EVMAddress(bytes: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
        
        // If pool doesn't exist, create and initialize it
        if poolAddr.bytes == zeroAddress.bytes {
            // Pool doesn't exist, create it
            var calldata = EVM.encodeABIWithSignature(
                "createPool(address,address,uint24)",
                [token0, token1, UInt256(fee)]
            )
            var result = self.coa.call(
                to: factory,
                data: calldata,
                gasLimit: 5000000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "Pool creation failed")
            
            // Get the newly created pool address
            getPoolResult = self.coa.dryCall(to: factory, data: getPoolCalldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
            
            assert(getPoolResult.status == EVM.Status.successful && getPoolResult.data.length >= 20, message: "Failed to get pool address after creation")
            
            poolAddr = (EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: getPoolResult.data)[0] as! EVM.EVMAddress)
            
            // Initialize the pool with the target price
            let initPrice = targetSqrtPriceX96
            calldata = EVM.encodeABIWithSignature(
                "initialize(uint160)",
                [initPrice]
            )
            result = self.coa.call(
                to: poolAddr,
                data: calldata,
                gasLimit: 5000000,
                value: EVM.Balance(attoflow: 0)
            )
            
            assert(result.status == EVM.Status.successful, message: "Pool initialization failed")
        }
        
        let poolAddress = poolAddr.toString()
        
        // Read pool parameters (tickSpacing is CRITICAL)
        let tickSpacingCalldata = EVM.encodeABIWithSignature("tickSpacing()", [])
        let spacingResult = self.coa.dryCall(
            to: poolAddr,
            data: tickSpacingCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
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
        
        // CRITICAL: Recalculate sqrtPriceX96 from the ALIGNED tick to ensure consistency
        // After rounding tick to tickSpacing, sqrtPriceX96 must match the aligned tick
        targetSqrtPriceX96 = calculateSqrtPriceX96FromTick(tick: targetTickAligned)
        
        // Use FULL RANGE ticks (min/max for Uniswap V3)
        // This ensures liquidity is available at any price
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
        let sqrtPriceU256 = targetSqrtPriceX96
        
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

        // Fund pool with balanced token amounts (1 billion logical tokens for each)
        // Need to account for decimal differences between tokens
        
        // Calculate 1 billion tokens in each token's decimal format
        // 1,000,000,000 * 10^decimals
        var token0Balance: UInt256 = 1000000000
        var i: UInt8 = 0
        while i < token0Decimals {
            token0Balance = token0Balance * 10
            i = i + 1
        }
        
        var token1Balance: UInt256 = 1000000000
        i = 0
        while i < token1Decimals {
            token1Balance = token1Balance * 10
            i = i + 1
        }
        
        // Convert to hex and pad to 32 bytes
        let token0BalanceHex = "0x".concat(String.encodeHex(token0Balance.toBigEndianBytes()))
        let token1BalanceHex = "0x".concat(String.encodeHex(token1Balance.toBigEndianBytes()))
        
        // Set token0 balance
        let token0BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token0BalanceSlot)
        EVM.store(target: token0, slot: token0BalanceSlotComputed, value: token0BalanceHex)
        
        // Set token1 balance
        let token1BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token1BalanceSlot)
        EVM.store(target: token1, slot: token1BalanceSlotComputed, value: token1BalanceHex)
    }
}

/// Calculate sqrtPriceX96 from tick using Uniswap V3's formula
/// sqrtPriceX96 = 1.0001^(tick/2) * 2^96
/// This ensures consistency with Uniswap's tick-to-price conversion
/// NOTE: This is kept for reference but not used - we calculate sqrtPriceX96 directly from price
access(self) fun calculateSqrtPriceX96FromTick(tick: Int256): UInt256 {
    // sqrtPriceX96 = 1.0001^(tick/2) * 2^96
    // = exp(tick/2 * ln(1.0001)) * 2^96
    // = exp(tick * ln(sqrt(1.0001))) * 2^96
    
    // ln(sqrt(1.0001)) = ln(1.0001) / 2 ≈ 0.00009999500033 / 2 ≈ 0.000049997500165
    // ln(sqrt(1.0001)) * 10^18 ≈ 49997500166541
    let lnSqrt1_0001 = Int256(49997500166541)
    let scaleFactor = UInt256(1000000000000000000) // 10^18
    
    // Calculate tick * ln(sqrt(1.0001))
    let exponent = tick * lnSqrt1_0001  // This is scaled by 10^18
    
    // Calculate exp(exponent / 10^18) * scaleFactor using Taylor series
    let expValue = expInt256(x: exponent, scaleFactor: scaleFactor)
    
    // expValue is now exp(tick * ln(sqrt(1.0001))) * 10^18
    // We want: exp(...) * 2^96
    // = (expValue / 10^18) * 2^96
    // = expValue * 2^96 / 10^18
    
    let twoTo96 = (UInt256(1) << 96)
    let sqrtPriceX96 = (expValue * twoTo96) / scaleFactor
    
    return sqrtPriceX96
}

/// Calculate e^x for Int256 x (can be negative) using Taylor series
/// Returns e^(x/scaleFactor) * scaleFactor
access(self) fun expInt256(x: Int256, scaleFactor: UInt256): UInt256 {
    // Handle negative exponents: e^(-x) = 1 / e^x
    if x < 0 {
        let posExp = expInt256(x: -x, scaleFactor: scaleFactor)
        // Return scaleFactor^2 / posExp
        return (scaleFactor * scaleFactor) / posExp
    }
    
    // For positive x, use Taylor series: e^x = 1 + x + x^2/2! + x^3/3! + ...
    // x is already scaled by scaleFactor
    let xU = UInt256(x)
    
    var sum = scaleFactor  // Start with 1 * scaleFactor
    var term = scaleFactor  // Current term in series
    var i = UInt256(1)
    
    // Calculate up to 50 terms for precision
    while i <= 50 && term > 0 {
        // term = term * x / (i * scaleFactor)
        term = (term * xU) / (i * scaleFactor)
        sum = sum + term
        i = i + 1
        
        // Stop if term becomes negligible
        if term < scaleFactor / UInt256(1000000000000) {
            break
        }
    }
    
    return sum
}

/// Calculate tick from price ratio
/// Returns tick = floor(log_1.0001(price)) for Uniswap V3 tick spacing
/// decimalOffset: (token1Decimals - token0Decimals) to adjust for raw EVM units
access(self) fun calculateTick(price: UFix64, decimalOffset: Int): Int256 {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places, stored as int * 10^8)
    let priceBytes = price.toBigEndianBytes()
    var priceUInt64: UInt64 = 0
    for byte in priceBytes {
        priceUInt64 = (priceUInt64 << 8) + UInt64(byte)
    }
    
    // priceUInt64 is price * 10^8
    //
    // For decimal offset adjustment:
    // - If decOffset > 0: multiply price (token1 has MORE decimals than token0)
    // - If decOffset < 0: divide price (token1 has FEWER decimals than token0)
    //
    // To avoid underflow when dividing, we adjust using logarithm properties
    // For example, with decOffset = -12:
    //   - Raw price = human_price / 10^12
    //   - ln(raw_price) = ln(human_price / 10^12) = ln(human_price) - ln(10^12)
    //   - ln(10^12) = 12 * ln(10) = 12 * 2.302585093... ≈ 27.631021115...
    //   - ln(10) * 10^18 ≈ 2302585092994045684 (for scale factor 10^18)
    
    let priceScaled = UInt256(priceUInt64) * UInt256(10000000000) // price * 10^18
    let scaleFactor = UInt256(1000000000000000000) // 10^18
    
    // Calculate ln(price) * 10^18 (without decimal adjustment yet)
    var lnPrice = lnUInt256(x: priceScaled, scaleFactor: scaleFactor)
    
    // Apply decimal offset adjustment to ln(price)
    // ln(price * 10^decOffset) = ln(price) + decOffset * ln(10)
    if decimalOffset != 0 {
        // ln(10) * 10^18 ≈ 2302585092994045684
        let ln10 = Int256(2302585092994045684)
        let adjustment = Int256(decimalOffset) * ln10
        lnPrice = lnPrice + adjustment
    }
    
    // ln(1.0001) * 10^18 ≈ 99995000333083
    let ln1_0001 = Int256(99995000333083)
    
    // tick = ln(adjusted_price) / ln(1.0001)
    let tick = lnPrice / ln1_0001
    
    return tick
}

/// Calculate square root using Newton's method for UInt256
/// Returns sqrt(n) * scaleFactor to maintain precision
access(self) fun sqrtUInt256(n: UInt256, scaleFactor: UInt256): UInt256 {
    if n == UInt256(0) {
        return UInt256(0)
    }
    
    // Initial guess: n/2 (scaled)
    var x = (n * scaleFactor) / UInt256(2)
    var prevX = UInt256(0)
    
    // Newton's method: x_new = (x + n*scale^2/x) / 2
    // Iterate until convergence (max 50 iterations for safety)
    var iterations = 0
    while x != prevX && iterations < 50 {
        prevX = x
        // x_new = (x + (n * scaleFactor^2) / x) / 2
        let nScaled = n * scaleFactor * scaleFactor
        x = (x + nScaled / x) / UInt256(2)
        iterations = iterations + 1
    }
    
    return x
}

/// Calculate natural logarithm using Taylor series
/// ln(x) for x > 0, returns ln(x) * scaleFactor for precision
access(self) fun lnUInt256(x: UInt256, scaleFactor: UInt256): Int256 {
    if x == UInt256(0) {
        panic("ln(0) is undefined")
    }
    
    // For better convergence, reduce x to range [0.5, 1.5] using:
    // ln(x) = ln(2^n * y) = n*ln(2) + ln(y) where y is in [0.5, 1.5]
    
    var value = x
    var n = 0
    
    // Scale down if x > 1.5 * scaleFactor
    let threshold = (scaleFactor * UInt256(3)) / UInt256(2)
    while value > threshold {
        value = value / UInt256(2)
        n = n + 1
    }
    
    // Scale up if x < 0.5 * scaleFactor
    let lowerThreshold = scaleFactor / UInt256(2)
    while value < lowerThreshold {
        value = value * UInt256(2)
        n = n - 1
    }
    
    // Now value is in [0.5*scale, 1.5*scale], compute ln(value/scale)
    // Use Taylor series: ln(1+z) = z - z^2/2 + z^3/3 - z^4/4 + ...
    // where z = value/scale - 1
    
    let z = value > scaleFactor 
        ? Int256(value - scaleFactor)
        : -Int256(scaleFactor - value)
    
    // Calculate Taylor series terms until convergence
    var result = z // First term: z
    var term = z
    var i = 2
    var prevResult = Int256(0)
    
    // Calculate terms until convergence (term becomes negligible or result stops changing)
    // Max 50 iterations for safety
    while i <= 50 && result != prevResult {
        prevResult = result
        
        // term = term * z / scaleFactor
        term = (term * z) / Int256(scaleFactor)
        
        // Add or subtract term/i based on sign
        if i % 2 == 0 {
            result = result - term / Int256(i)
        } else {
            result = result + term / Int256(i)
        }
        i = i + 1
    }
    
    // Add n * ln(2) * scaleFactor
    // ln(2) ≈ 0.693147180559945309417232121458
    // ln(2) * 10^18 ≈ 693147180559945309
    let ln2Scaled = Int256(693147180559945309)
    let nScaled = Int256(n) * ln2Scaled
    
    // Scale to our scaleFactor (assuming scaleFactor is 10^18)
    result = result + nScaled
    
    return result
}

access(all) fun getTokenDecimals(evmContractAddress: EVM.EVMAddress): UInt8 {
    let zeroAddress = EVM.addressFromString("0x0000000000000000000000000000000000000000")
    let callResult = EVM.dryCall(
        from: zeroAddress,
        to: evmContractAddress,
        data: EVM.encodeABIWithSignature("decimals()", []),
        gasLimit: 100000,
        value: EVM.Balance(attoflow: 0)
    )

    assert(callResult.status == EVM.Status.successful, message: "Call for EVM asset decimals failed")
    return (EVM.decodeABI(types: [Type<UInt8>()], data: callResult.data)[0] as! UInt8)
}
