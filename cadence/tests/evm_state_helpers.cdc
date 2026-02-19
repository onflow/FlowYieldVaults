import Test
import "EVM"

/* --- ERC4626 Vault State Manipulation --- */

/// Set vault share price by setting totalAssets to a specific base value, then multiplying by the price multiplier
/// Manipulates both asset.balanceOf(vault) and vault._totalAssets to bypass maxRate capping
/// Caller should provide baseAssets large enough to prevent slippage during price changes
access(all) fun setVaultSharePrice(
    vaultAddress: String,
    assetAddress: String,
    assetBalanceSlot: UInt256,
    totalSupplySlot: UInt256,
    vaultTotalAssetsSlot: UInt256,
    baseAssets: UFix64,
    priceMultiplier: UFix64,
    signer: Test.TestAccount
) {
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_erc4626_vault_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [vaultAddress, assetAddress, assetBalanceSlot, totalSupplySlot, vaultTotalAssetsSlot, baseAssets, priceMultiplier]
        )
    )
    Test.expect(result, Test.beSucceeded())
}

/* --- Uniswap V3 Pool State Manipulation --- */

/// Set Uniswap V3 pool to a specific price via EVM.store
/// Creates pool if it doesn't exist, then manipulates state
access(all) fun setPoolToPrice(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix64,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256,
    signer: Test.TestAccount,
    tokenADecimals: Int,
    tokenBDecimals: Int
) {
    // Sort tokens (Uniswap V3 requires token0 < token1)
    let token0 = tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress
    let token1 = tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress
    let token0BalanceSlot = tokenAAddress < tokenBAddress ? tokenABalanceSlot : tokenBBalanceSlot
    let token1BalanceSlot = tokenAAddress < tokenBAddress ? tokenBBalanceSlot : tokenABalanceSlot
    
    let poolPrice = tokenAAddress < tokenBAddress ? priceTokenBPerTokenA : 1.0 / priceTokenBPerTokenA
    
    // Calculate decimal offset for sorted tokens
    let token0Decimals = tokenAAddress < tokenBAddress ? tokenADecimals : tokenBDecimals
    let token1Decimals = tokenAAddress < tokenBAddress ? tokenBDecimals : tokenADecimals
    let decOffset = token1Decimals - token0Decimals
    
    // Calculate base price/tick
    var targetSqrtPriceX96 = calculateSqrtPriceX96(price: poolPrice)
    var targetTick = calculateTick(price: poolPrice)
    
    // Apply decimal offset if needed (MINIMAL change)
    if decOffset != 0 {
        // Adjust sqrtPriceX96: multiply/divide by 10^(decOffset/2)
        var sqrtPriceU256 = UInt256.fromString(targetSqrtPriceX96)!
        let absHalfOffset = decOffset < 0 ? (-decOffset) / 2 : decOffset / 2
        var pow10: UInt256 = 1
        var i = 0
        while i < absHalfOffset {
            pow10 = pow10 * 10
            i = i + 1
        }
        if decOffset > 0 {
            sqrtPriceU256 = sqrtPriceU256 * pow10
        } else {
            sqrtPriceU256 = sqrtPriceU256 / pow10
        }
        targetSqrtPriceX96 = sqrtPriceU256.toString()
        
        // Adjust tick: add/subtract decOffset * 23026 (ticks per decimal)
        targetTick = targetTick + Int256(decOffset) * 23026
    }
    
    log("[setPoolToPrice] tokenA=\(tokenAAddress) tokenB=\(tokenBAddress) fee=\(fee) price=\(poolPrice) decOffset=\(decOffset) tick=\(targetTick.toString())")
    
    let createResult = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/ensure_uniswap_pool_exists.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [factoryAddress, token0, token1, fee, targetSqrtPriceX96]
        )
    )
    Test.expect(createResult, Test.beSucceeded())
    
    let seedResult = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_uniswap_v3_pool_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [factoryAddress, token0, token1, fee, targetSqrtPriceX96, targetTick, token0BalanceSlot, token1BalanceSlot]
        )
    )
    Test.expect(seedResult, Test.beSucceeded())
}

/* --- Internal Math Utilities --- */

/// Calculate sqrtPriceX96 from a price ratio
/// Returns sqrt(price) * 2^96 as a string for Uniswap V3 pool initialization
access(self) fun calculateSqrtPriceX96(price: UFix64): String {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places)
    // price is stored as integer * 10^8 internally
    let priceBytes = price.toBigEndianBytes()
    var priceUInt64: UInt64 = 0
    for byte in priceBytes {
        priceUInt64 = (priceUInt64 << 8) + UInt64(byte)
    }
    let priceScaled = UInt256(priceUInt64) // This is price * 10^8
    
    // We want: sqrt(price) * 2^96
    // = sqrt(priceScaled / 10^8) * 2^96
    // = sqrt(priceScaled) * 2^96 / sqrt(10^8)
    // = sqrt(priceScaled) * 2^96 / 10^4
    
    // Calculate sqrt(priceScaled) with scale factor 2^48 for precision
    // sqrt(priceScaled) * 2^48
    let sqrtPriceScaled = sqrt(n: priceScaled, scaleFactor: UInt256(1) << 48)
    
    // Now we have: sqrt(priceScaled) * 2^48
    // We want: sqrt(priceScaled) * 2^96 / 10^4
    // = (sqrt(priceScaled) * 2^48) * 2^48 / 10^4
    
    let sqrtPriceX96 = (sqrtPriceScaled * (UInt256(1) << 48)) / UInt256(10000)
    
    return sqrtPriceX96.toString()
}

/// Calculate tick from price ratio
/// Returns tick = floor(log_1.0001(price)) for Uniswap V3 tick spacing
access(self) fun calculateTick(price: UFix64): Int256 {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places, stored as int * 10^8)
    let priceBytes = price.toBigEndianBytes()
    var priceUInt64: UInt64 = 0
    for byte in priceBytes {
        priceUInt64 = (priceUInt64 << 8) + UInt64(byte)
    }
    
    // priceUInt64 is price * 10^8
    // Scale to 10^18 for precision: price * 10^18 = priceUInt64 * 10^10
    let priceScaled = UInt256(priceUInt64) * UInt256(10000000000) // 10^10
    let scaleFactor = UInt256(1000000000000000000) // 10^18
    
    // Calculate ln(price) * 10^18
    let lnPrice = ln(x: priceScaled, scaleFactor: scaleFactor)
    
    // ln(1.0001) * 10^18 ≈ 99995000333083
    let ln1_0001 = Int256(99995000333083)
    
    // tick = ln(price) / ln(1.0001)
    // lnPrice is already scaled by 10^18
    // ln1_0001 is already scaled by 10^18  
    // So: tick = (lnPrice * 10^18) / (ln1_0001 * 10^18) = lnPrice / ln1_0001
    
    let tick = lnPrice / ln1_0001
    
    return tick
}

/* --- Internal Math Utilities --- */

/// Calculate square root using Newton's method for UInt256
/// Returns sqrt(n) * scaleFactor to maintain precision
access(self) fun sqrt(n: UInt256, scaleFactor: UInt256): UInt256 {
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
access(self) fun ln(x: UInt256, scaleFactor: UInt256): Int256 {
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
