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

// Helper: Convert UInt256 to zero-padded 64-char hex string (32 bytes)
access(all) fun toHex32(_ value: UInt256): String {
    let raw = value.toBigEndianBytes()
    var padded: [UInt8] = []
    var padCount = 32 - raw.length
    while padCount > 0 {
        padded.append(0)
        padCount = padCount - 1
    }
    padded = padded.concat(raw)
    return String.encodeHex(padded)
}

// Helper: Convert a slot number (UInt256) to its padded hex string for EVM.store/load
access(all) fun slotHex(_ slotNum: UInt256): String {
    return "0x\(toHex32(slotNum))"
}

// Helper: Parse a hex slot string back to UInt256
access(all) fun slotToNum(_ slot: String): UInt256 {
    var hex = slot
    if hex.length > 2 && hex.slice(from: 0, upTo: 2) == "0x" {
        hex = hex.slice(from: 2, upTo: hex.length)
    }
    let bytes = hex.decodeHex()
    var num = 0 as UInt256
    for byte in bytes {
        num = num * 256 + UInt256(byte)
    }
    return num
}

// Properly seed Uniswap V3 pool with STRUCTURALLY VALID state
// This creates: slot0, observations, liquidity, ticks (with initialized flag), bitmap, and token balances
// Pass 0.0 for tvl and concentration to create a full-range infinite liquidity pool (useful for no slippage)
transaction(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix128,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256,
    tvl: UFix64,
    concentration: UFix64,
    tokenBPriceUSD: UFix64
) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    prepare(signer: auth(Storage) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA")
    }

    execute {
        // Convert UFix128 (scale 1e24) to num/den fraction for exact integer arithmetic
        let priceBytes = priceTokenBPerTokenA.toBigEndianBytes()
        var priceNum: UInt256 = 0
        for byte in priceBytes {
            priceNum = (priceNum << 8) + UInt256(byte)
        }
        let priceDen: UInt256 = 1_000_000_000_000_000_000_000_000 // 1e24

        // Sort tokens (Uniswap V3 requires token0 < token1)
        let factory = EVM.addressFromString(factoryAddress)
        let token0 = EVM.addressFromString(tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress)
        let token1 = EVM.addressFromString(tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress)
        let token0BalanceSlot = tokenAAddress < tokenBAddress ? tokenABalanceSlot : tokenBBalanceSlot
        let token1BalanceSlot = tokenAAddress < tokenBAddress ? tokenBBalanceSlot : tokenABalanceSlot

        // Price is token1/token0. If tokenA < tokenB, priceTokenBPerTokenA = token1/token0 = num/den.
        // If tokenA > tokenB, we need to invert: token1/token0 = den/num.
        let poolPriceNum = tokenAAddress < tokenBAddress ? priceNum : priceDen
        let poolPriceDen = tokenAAddress < tokenBAddress ? priceDen : priceNum

        // Read decimals from EVM
        let token0Decimals = getTokenDecimals(evmContractAddress: token0)
        let token1Decimals = getTokenDecimals(evmContractAddress: token1)
        let decOffset = Int(token1Decimals) - Int(token0Decimals)

        // Compute sqrtPriceX96 from price fraction with full precision.
        // poolPrice = poolPriceNum / poolPriceDen (token1/token0 in whole-token terms)
        // rawPrice = poolPrice * 10^decOffset (converts to smallest-unit ratio)
        // sqrtPriceX96 = floor(sqrt(rawPrice) * 2^96) computed via 512-bit binary search.

        let targetSqrtPriceX96 = sqrtPriceX96FromPrice(
            priceNum: poolPriceNum,
            priceDen: poolPriceDen,
            decOffset: decOffset
        )
        let targetTick = getTickAtSqrtRatio(sqrtPriceX96: targetSqrtPriceX96)

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
            calldata = EVM.encodeABIWithSignature(
                "initialize(uint160)",
                [targetSqrtPriceX96]
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
        
        // Read pool parameters (tickSpacing)
        let tickSpacingCalldata = EVM.encodeABIWithSignature("tickSpacing()", [])
        let spacingResult = self.coa.dryCall(
            to: poolAddr,
            data: tickSpacingCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(spacingResult.status == EVM.Status.successful, message: "Failed to read tickSpacing")
        
        let tickSpacing = (EVM.decodeABI(types: [Type<Int256>()], data: spacingResult.data)[0] as! Int256)

        // Compute tick range, liquidity, and token balances based on TVL mode
        let Q96: UInt256 = UInt256(1) << 96
        var tickLower: Int256 = 0
        var tickUpper: Int256 = 0
        var liquidityAmount: UInt256 = 0
        var token0Balance: UInt256 = 0
        var token1Balance: UInt256 = 0

        if tvl > 0.0 && concentration > 0.0 && concentration < 1.0 {
            // --- Concentrated liquidity mode ---
            let halfWidth = 1.0 - concentration

            // sqrt(1 +/- halfWidth) via integer sqrt at 1e16 scale for 8-digit precision
            let PRECISION: UInt256 = 10_000_000_000_000_000
            let SQRT_PRECISION: UInt256 = 100_000_000
            let halfWidthScaled = UInt256(UInt64(halfWidth * 100_000_000.0)) * 100_000_000

            let upperMultNum = isqrt(PRECISION + halfWidthScaled)
            let lowerMultNum = isqrt(PRECISION - halfWidthScaled)

            var sqrtPriceUpper = targetSqrtPriceX96 * upperMultNum / SQRT_PRECISION
            var sqrtPriceLower = targetSqrtPriceX96 * lowerMultNum / SQRT_PRECISION

            let MAX_SQRT: UInt256 = 1461446703485210103287273052203988822378723970341
            let MIN_SQRT: UInt256 = 4295128739
            if sqrtPriceUpper > MAX_SQRT { sqrtPriceUpper = MAX_SQRT }
            if sqrtPriceLower < MIN_SQRT + 1 { sqrtPriceLower = MIN_SQRT + 1 }

            let rawTickUpper = getTickAtSqrtRatio(sqrtPriceX96: sqrtPriceUpper)
            let rawTickLower = getTickAtSqrtRatio(sqrtPriceX96: sqrtPriceLower)

            // Align tickLower down, tickUpper up to tickSpacing
            tickLower = rawTickLower / tickSpacing * tickSpacing
            if rawTickLower < 0 && rawTickLower % tickSpacing != 0 {
                tickLower = tickLower - tickSpacing
            }
            tickUpper = rawTickUpper / tickSpacing * tickSpacing
            if rawTickUpper > 0 && rawTickUpper % tickSpacing != 0 {
                tickUpper = tickUpper + tickSpacing
            }

            assert(tickLower < tickUpper, message: "Concentrated tick range is empty after alignment")

            let sqrtPa = getSqrtRatioAtTick(tick: tickLower)
            let sqrtPb = getSqrtRatioAtTick(tick: tickUpper)

            // Convert TVL/2 from USD to token1 smallest units using token prices
            let effectiveBPrice = tokenBPriceUSD > 0.0 ? tokenBPriceUSD : 1.0
            var token1PriceUSD = effectiveBPrice
            if tokenAAddress >= tokenBAddress {
                // token1 = tokenA; tokenA is worth priceTokenBPerTokenA * tokenBPrice in USD
                token1PriceUSD = UFix64(priceTokenBPerTokenA) * effectiveBPrice
            }
            let tvlHalfToken1 = tvl / 2.0 / token1PriceUSD
            let tvlHalfWhole = UInt256(UInt64(tvlHalfToken1))
            var tvlHalfSmallest = tvlHalfWhole
            var td: UInt8 = 0
            while td < token1Decimals {
                tvlHalfSmallest = tvlHalfSmallest * 10
                td = td + 1
            }

            // L = tvlHalfSmallest * Q96 / (sqrtP - sqrtPa)
            let sqrtPDiffA = targetSqrtPriceX96 - sqrtPa
            assert(sqrtPDiffA > 0, message: "sqrtP must be > sqrtPa for liquidity calculation")
            liquidityAmount = tvlHalfSmallest * Q96 / sqrtPDiffA

            // token1 = L * (sqrtP - sqrtPa) / Q96
            token1Balance = liquidityAmount * sqrtPDiffA / Q96

            // token0 = L * (sqrtPb - sqrtP) / sqrtPb * Q96 / sqrtP
            let sqrtPDiffB = sqrtPb - targetSqrtPriceX96
            token0Balance = liquidityAmount * sqrtPDiffB / sqrtPb * Q96 / targetSqrtPriceX96
        } else {
            // --- Full-range infinite liquidity mode (backward compatible) ---
            tickLower = (-887272 as Int256) / tickSpacing * tickSpacing
            tickUpper = (887272 as Int256) / tickSpacing * tickSpacing
            liquidityAmount = 340282366920938463463374607431768211455 // 2^128 - 1

            token0Balance = 1000000000
            var ti: UInt8 = 0
            while ti < token0Decimals {
                token0Balance = token0Balance * 10
                ti = ti + 1
            }
            token1Balance = 1000000000
            ti = 0
            while ti < token1Decimals {
                token1Balance = token1Balance * 10
                ti = ti + 1
            }
        }

        // Pack slot0 for Solidity storage layout
        // Struct fields packed right-to-left (LSB to MSB):
        //   sqrtPriceX96 (160 bits) | tick (24 bits) | observationIndex (16 bits) |
        //   observationCardinality (16 bits) | observationCardinalityNext (16 bits) |
        //   feeProtocol (8 bits) | unlocked (8 bits)

        // Convert tick to 24-bit two's complement
        let tickMask = UInt256(((1 as Int256) << 24) - 1)  // 0xFFFFFF
        let tickU = UInt256(
            targetTick < 0
                ? ((1 as Int256) << 24) + targetTick
                : targetTick
        ) & tickMask

        var packedValue = targetSqrtPriceX96                           // bits [0:159]
        packedValue = packedValue + (tickU << UInt256(160))          // bits [160:183]
        // observationIndex = 0                                      // bits [184:199]
        packedValue = packedValue + (UInt256(1) << UInt256(200))     // observationCardinality = 1 at bits [200:215]
        packedValue = packedValue + (UInt256(1) << UInt256(216))     // observationCardinalityNext = 1 at bits [216:231]
        // feeProtocol = 0                                           // bits [232:239]
        packedValue = packedValue + (UInt256(1) << UInt256(240))     // unlocked = 1 at bits [240:247]

        let slot0Value = toHex32(packedValue)
        assert(slot0Value.length == 64, message: "slot0 must be 64 hex chars")

        // --- Slot 0: slot0 (packed) ---
        EVM.store(target: poolAddr, slot: slotHex(0), value: slot0Value)

        // Verify round-trip
        let readBack = EVM.load(target: poolAddr, slot: slotHex(0))
        let readBackHex = String.encodeHex(readBack)
        assert(readBackHex == slot0Value, message: "slot0 read-back mismatch - storage corruption!")

        // --- Slots 1-3: feeGrowthGlobal0X128, feeGrowthGlobal1X128, protocolFees = 0 ---
        let zero32 = "0000000000000000000000000000000000000000000000000000000000000000"
        EVM.store(target: poolAddr, slot: slotHex(1), value: zero32)
        EVM.store(target: poolAddr, slot: slotHex(2), value: zero32)
        EVM.store(target: poolAddr, slot: slotHex(3), value: zero32)

        // --- Slot 4: liquidity ---
        EVM.store(target: poolAddr, slot: slotHex(4), value: toHex32(liquidityAmount))

        // --- Initialize boundary ticks ---
        // Tick storage layout per tick (4 consecutive slots):
        //   Slot 0: [liquidityNet (int128, upper 128 bits)] [liquidityGross (uint128, lower 128 bits)]
        //   Slot 1: feeGrowthOutside0X128
        //   Slot 2: feeGrowthOutside1X128
        //   Slot 3: packed(tickCumulativeOutside, secondsPerLiquidity, secondsOutside, initialized)

        // Pack tick slot 0: liquidityGross (lower 128) + liquidityNet (upper 128)
        // For lower tick: liquidityNet = +L, for upper tick: liquidityNet = -L
        let liquidityGross = liquidityAmount
        let liquidityNetPositive = liquidityAmount
        // Two's complement of -L in 128 bits: 2^128 - L
        let twoTo128 = UInt256(1) << 128
        let liquidityNetNegative = twoTo128 - liquidityAmount

        // Lower tick: liquidityNet = +L (upper 128 bits), liquidityGross = L (lower 128 bits)
        let tickLowerData0 = toHex32((liquidityNetPositive << 128) + liquidityGross)

        let tickLowerSlot = computeMappingSlot([tickLower, 5])
        let tickLowerSlotNum = slotToNum(tickLowerSlot)

        EVM.store(target: poolAddr, slot: tickLowerSlot, value: tickLowerData0)
        EVM.store(target: poolAddr, slot: slotHex(tickLowerSlotNum + 1), value: zero32) // feeGrowthOutside0X128
        EVM.store(target: poolAddr, slot: slotHex(tickLowerSlotNum + 2), value: zero32) // feeGrowthOutside1X128
        // Slot 3: initialized=true (highest byte)
        EVM.store(target: poolAddr, slot: slotHex(tickLowerSlotNum + 3), value: "0100000000000000000000000000000000000000000000000000000000000000")

        // Upper tick: liquidityNet = -L (upper 128 bits), liquidityGross = L (lower 128 bits)
        let tickUpperData0 = toHex32((liquidityNetNegative << 128) + liquidityGross)

        let tickUpperSlot = computeMappingSlot([tickUpper, 5])
        let tickUpperSlotNum = slotToNum(tickUpperSlot)

        EVM.store(target: poolAddr, slot: tickUpperSlot, value: tickUpperData0)
        EVM.store(target: poolAddr, slot: slotHex(tickUpperSlotNum + 1), value: zero32)
        EVM.store(target: poolAddr, slot: slotHex(tickUpperSlotNum + 2), value: zero32)
        EVM.store(target: poolAddr, slot: slotHex(tickUpperSlotNum + 3), value: "0100000000000000000000000000000000000000000000000000000000000000")

        // --- Set tick bitmaps (OR with existing values) ---

        let compressedLower = tickLower / tickSpacing
        let wordPosLower = compressedLower / 256
        var bitPosLower = compressedLower % 256
        if bitPosLower < 0 { bitPosLower = bitPosLower + 256 }

        let compressedUpper = tickUpper / tickSpacing
        let wordPosUpper = compressedUpper / 256
        var bitPosUpper = compressedUpper % 256
        if bitPosUpper < 0 { bitPosUpper = bitPosUpper + 256 }

        // Lower tick bitmap: OR with existing
        let bitmapLowerSlot = computeMappingSlot([wordPosLower, 6])
        let existingLowerBitmap = bytesToUInt256(EVM.load(target: poolAddr, slot: bitmapLowerSlot))
        let newLowerBitmap = existingLowerBitmap | (UInt256(1) << UInt256(bitPosLower))
        EVM.store(target: poolAddr, slot: bitmapLowerSlot, value: toHex32(newLowerBitmap))

        // Upper tick bitmap: OR with existing
        let bitmapUpperSlot = computeMappingSlot([wordPosUpper, UInt256(6)])
        let existingUpperBitmap = bytesToUInt256(EVM.load(target: poolAddr, slot: bitmapUpperSlot))
        let newUpperBitmap = existingUpperBitmap | (UInt256(1) << UInt256(bitPosUpper))
        EVM.store(target: poolAddr, slot: bitmapUpperSlot, value: toHex32(newUpperBitmap))

        // --- Slot 8: observations[0] (REQUIRED or swaps will revert!) ---
        // Solidity packing (big-endian storage word):
        //   [initialized(1)] [secondsPerLiquidity(20)] [tickCumulative(7)] [blockTimestamp(4)]
        let currentTimestamp = UInt32(getCurrentBlock().timestamp)

        var obs0Bytes: [UInt8] = []
        obs0Bytes.append(1)                                             // initialized = true
        obs0Bytes.appendAll([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]) // secondsPerLiquidityCumulativeX128
        obs0Bytes.appendAll([0,0,0,0,0,0,0])                            // tickCumulative
        obs0Bytes.appendAll(currentTimestamp.toBigEndianBytes())          // blockTimestamp

        assert(obs0Bytes.length == 32, message: "observations[0] must be exactly 32 bytes")

        EVM.store(target: poolAddr, slot: slotHex(8), value: String.encodeHex(obs0Bytes))

        // --- Fund pool with token balances ---
        let token0BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token0BalanceSlot)
        EVM.store(target: token0, slot: token0BalanceSlotComputed, value: toHex32(token0Balance))

        let token1BalanceSlotComputed = computeBalanceOfSlot(holderAddress: poolAddress, balanceSlot: token1BalanceSlot)
        EVM.store(target: token1, slot: token1BalanceSlotComputed, value: toHex32(token1Balance))
    }
}

// ============================================================================
// Canonical Uniswap V3 TickMath — ported from Solidity
// ============================================================================

/// Canonical port of TickMath.getSqrtRatioAtTick
/// Calculates sqrt(1.0001^tick) * 2^96 using the exact same bit-decomposition
/// and fixed-point constants as the Solidity implementation.
access(all) fun getSqrtRatioAtTick(tick: Int256): UInt256 {
    let absTick: UInt256 = tick < 0 ? UInt256(-tick) : UInt256(tick)
    assert(absTick <= 887272, message: "T")

    var ratio: UInt256 = (absTick & 0x1) != 0
        ? 0xfffcb933bd6fad37aa2d162d1a594001
        : 0x100000000000000000000000000000000

    if (absTick & 0x2) != 0 { ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128 }
    if (absTick & 0x4) != 0 { ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128 }
    if (absTick & 0x8) != 0 { ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128 }
    if (absTick & 0x10) != 0 { ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128 }
    if (absTick & 0x20) != 0 { ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128 }
    if (absTick & 0x40) != 0 { ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128 }
    if (absTick & 0x80) != 0 { ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128 }
    if (absTick & 0x100) != 0 { ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128 }
    if (absTick & 0x200) != 0 { ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128 }
    if (absTick & 0x400) != 0 { ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128 }
    if (absTick & 0x800) != 0 { ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128 }
    if (absTick & 0x1000) != 0 { ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128 }
    if (absTick & 0x2000) != 0 { ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128 }
    if (absTick & 0x4000) != 0 { ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128 }
    if (absTick & 0x8000) != 0 { ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128 }
    if (absTick & 0x10000) != 0 { ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128 }
    if (absTick & 0x20000) != 0 { ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128 }
    if (absTick & 0x40000) != 0 { ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128 }
    if (absTick & 0x80000) != 0 { ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128 }

    if tick > 0 {
        // type(uint256).max / ratio
        ratio = UInt256.max / ratio
    }

    // Divide by 1<<32, rounding up: (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
    let remainder = ratio % (UInt256(1) << 32)
    let sqrtPriceX96 = (ratio >> 32) + (remainder == 0 ? 0 : 1 as UInt256)

    return sqrtPriceX96
}

/// Canonical port of TickMath.getTickAtSqrtRatio
/// Calculates the greatest tick value such that getSqrtRatioAtTick(tick) <= sqrtPriceX96
access(all) fun getTickAtSqrtRatio(sqrtPriceX96: UInt256): Int256 {
    assert(sqrtPriceX96 >= 4295128739 && sqrtPriceX96 < 1461446703485210103287273052203988822378723970342 as UInt256, message: "R")

    let ratio = sqrtPriceX96 << 32
    var r = ratio
    var msb: UInt256 = 0

    // Find MSB using binary search
    // f = (r > 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) ? 128 : 0
    var f: UInt256 = r > 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ? 128 : 0
    msb = msb | f
    r = r >> f

    f = r > 0xFFFFFFFFFFFFFFFF ? 64 : 0
    msb = msb | f
    r = r >> f

    f = r > 0xFFFFFFFF ? 32 : 0
    msb = msb | f
    r = r >> f

    f = r > 0xFFFF ? 16 : 0
    msb = msb | f
    r = r >> f

    f = r > 0xFF ? 8 : 0
    msb = msb | f
    r = r >> f

    f = r > 0xF ? 4 : 0
    msb = msb | f
    r = r >> f

    f = r > 0x3 ? 2 : 0
    msb = msb | f
    r = r >> f

    f = r > 0x1 ? 1 : 0
    msb = msb | f

    if msb >= 128 {
        r = ratio >> (msb - 127)
    } else {
        r = ratio << (127 - msb)
    }

    // Compute log_2 in Q64.64 fixed-point
    let _2_64: Int256 = 1 << 64
    var log_2: Int256 = (Int256(msb) - 128) * _2_64

    // 14 iterations of squaring to refine the fractional part
    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 63)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 62)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 61)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 60)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 59)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 58)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 57)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 56)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 55)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 54)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 53)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 52)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 51)
    r = r >> f

    r = (r * r) >> 127
    f = r >> 128
    log_2 = log_2 | Int256(f << 50)

    // log_sqrt10001 = log_2 * 255738958999603826347141 (128.128 number)
    let log_sqrt10001 = log_2 * 255738958999603826347141

    // Compute tick bounds
    let tickLow = Int256((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128)
    let tickHi = Int256((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128)

    if tickLow == tickHi {
        return tickLow
    }

    // Check which tick is correct
    let sqrtRatioAtTickHi = getSqrtRatioAtTick(tick: tickHi)
    if sqrtRatioAtTickHi <= sqrtPriceX96 {
        return tickHi
    }
    return tickLow
}

// ============================================================================
// 512-bit arithmetic for exact sqrtPriceX96 computation
// ============================================================================

/// Multiply two UInt256 values, returning a 512-bit result as [hi, lo].
///
/// Uses 64-bit limb decomposition to avoid any overflow in Cadence's non-wrapping arithmetic.
/// Each operand is split into four 64-bit limbs. Partial products (64×64→128 bits) fit
/// comfortably in UInt256, and we accumulate with carries tracked explicitly.
access(all) fun mul256x256(_ a: UInt256, _ b: UInt256): [UInt256; 2] {
    let MASK64: UInt256 = (1 << 64) - 1

    // Split a into 64-bit limbs: a = a3*2^192 + a2*2^128 + a1*2^64 + a0
    let a0 = a & MASK64
    let a1 = (a >> 64) & MASK64
    let a2 = (a >> 128) & MASK64
    let a3 = (a >> 192) & MASK64

    // Split b into 64-bit limbs
    let b0 = b & MASK64
    let b1 = (b >> 64) & MASK64
    let b2 = (b >> 128) & MASK64
    let b3 = (b >> 192) & MASK64

    // Result has 8 limbs (r0..r7), each 64 bits.
    // We accumulate into a carry variable as we go.
    // For each output limb position k, sum all ai*bj where i+j=k, plus carry from previous.

    // Limb 0 (position 0): a0*b0
    var acc = a0 * b0  // max 128 bits, fits in UInt256
    let r0 = acc & MASK64
    acc = acc >> 64

    // Limb 1 (position 64): a0*b1 + a1*b0
    acc = acc + a0 * b1 + a1 * b0
    let r1 = acc & MASK64
    acc = acc >> 64

    // Limb 2 (position 128): a0*b2 + a1*b1 + a2*b0
    acc = acc + a0 * b2 + a1 * b1 + a2 * b0
    let r2 = acc & MASK64
    acc = acc >> 64

    // Limb 3 (position 192): a0*b3 + a1*b2 + a2*b1 + a3*b0
    acc = acc + a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
    let r3 = acc & MASK64
    acc = acc >> 64

    // Limb 4 (position 256): a1*b3 + a2*b2 + a3*b1
    acc = acc + a1 * b3 + a2 * b2 + a3 * b1
    let r4 = acc & MASK64
    acc = acc >> 64

    // Limb 5 (position 320): a2*b3 + a3*b2
    acc = acc + a2 * b3 + a3 * b2
    let r5 = acc & MASK64
    acc = acc >> 64

    // Limb 6 (position 384): a3*b3
    acc = acc + a3 * b3
    let r6 = acc & MASK64
    let r7 = acc >> 64

    let lo = r0 + (r1 << 64) + (r2 << 128) + (r3 << 192)
    let hi = r4 + (r5 << 64) + (r6 << 128) + (r7 << 192)

    return [hi, lo]
}

/// Compare two 512-bit numbers: (aHi, aLo) <= (bHi, bLo)
access(all) fun lte512(aHi: UInt256, aLo: UInt256, bHi: UInt256, bLo: UInt256): Bool {
    if aHi != bHi { return aHi < bHi }
    return aLo <= bLo
}

/// Compute sqrtPriceX96 = floor(sqrt(price) * 2^96) exactly from a price fraction.
///
/// priceNum/priceDen: human price as an exact fraction (e.g. 1/3 for 0.333...)
/// decOffset: token1Decimals - token0Decimals
///
/// The raw price in smallest-unit terms is: rawPrice = (priceNum/priceDen) * 10^decOffset
/// We represent this as a fraction: num / den, where both are UInt256.
///
/// We want the largest y such that: y^2 / 2^192 <= num / den
/// Equivalently: y^2 * den <= num * 2^192
///
/// Both sides can exceed 256 bits (y is up to 160 bits, so y^2 is up to 320 bits),
/// so we use 512-bit arithmetic via mul256x256.
access(all) fun sqrtPriceX96FromPrice(priceNum: UInt256, priceDen: UInt256, decOffset: Int): UInt256 {
    // Build num and den such that rawPrice = num / den
    // rawPrice = (priceNum / priceDen) * 10^decOffset
    var num = priceNum
    var den = priceDen

    if decOffset >= 0 {
        var p = 0
        while p < decOffset {
            num = num * 10
            p = p + 1
        }
    } else {
        var p = 0
        while p < -decOffset {
            den = den * 10
            p = p + 1
        }
    }

    // We want largest y where y^2 * den <= num * 2^192
    // Compute RHS = num * 2^192 as 512-bit: num * 2^192 = (num << 192) split into (hi, lo)
    // num << 192: if num fits in 64 bits, num << 192 fits in ~256 bits
    // But to be safe, compute as: mul256x256(num, 2^192)
    // 2^192 = UInt256, so this is just a shift — but num could be large after scaling.
    // Use: rhsHi = num >> 64, rhsLo = num << 192
    let rhsHi = num >> 64
    let rhsLo = num << 192

    // Binary search over y in [MIN_SQRT_RATIO, MAX_SQRT_RATIO]
    let MIN_SQRT_RATIO: UInt256 = 4295128739
    let MAX_SQRT_RATIO: UInt256 = 1461446703485210103287273052203988822378723970341

    var lo = MIN_SQRT_RATIO
    var hi = MAX_SQRT_RATIO

    while lo < hi {
        // Use upper-mid to find the greatest y satisfying the condition
        let mid = lo + (hi - lo + 1) / 2

        // Compute mid^2 * den as 512-bit
        // sq[0] = hi, sq[1] = lo
        let sq = mul256x256(mid, mid)
        // Now multiply (sq[0], sq[1]) by den
        // = sq[0]*den * 2^256 + sq[1]*den
        // sq[1] * den may produce a 512-bit result
        let loProd = mul256x256(sq[1], den)
        let hiProd = sq[0] * den  // fits if sq[0] is small (which it is for valid sqrt ratios)
        let lhsHi = hiProd + loProd[0]
        let lhsLo = loProd[1]

        if lte512(aHi: lhsHi, aLo: lhsLo, bHi: rhsHi, bLo: rhsLo) {
            lo = mid
        } else {
            hi = mid - 1
        }
    }
    
    return lo
}

// ============================================================================
// Byte helpers
// ============================================================================

/// Parse raw bytes (from EVM.load) into UInt256. Works for any length <= 32.
access(all) fun bytesToUInt256(_ bytes: [UInt8]): UInt256 {
    var result: UInt256 = 0
    for byte in bytes {
        result = result * 256 + UInt256(byte)
    }
    return result
}

/// Integer square root via Newton's method. Returns floor(sqrt(x)).
access(all) fun isqrt(_ x: UInt256): UInt256 {
    if x == 0 { return 0 }
    var z = x
    var y = (z + 1) / 2
    while y < z {
        z = y
        y = (z + x / z) / 2
    }
    return z
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
