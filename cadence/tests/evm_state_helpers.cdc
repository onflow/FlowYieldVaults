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
    vaultTotalAssetsSlot: String,
    baseAssets: UFix64,
    priceMultiplier: UFix64,
    signer: Test.TestAccount
) {
    // Convert UFix64 baseAssets to UInt256 (UFix64 has 8 decimal places, stored as int * 10^8)
    let baseAssetsBytes = baseAssets.toBigEndianBytes()
    var baseAssetsUInt64: UInt64 = 0
    for byte in baseAssetsBytes {
        baseAssetsUInt64 = (baseAssetsUInt64 << 8) + UInt64(byte)
    }
    let baseAssetsUInt256 = UInt256(baseAssetsUInt64)
    
    // Calculate target: baseAssets * multiplier
    let multiplierBytes = priceMultiplier.toBigEndianBytes()
    var multiplierUInt64: UInt64 = 0
    for byte in multiplierBytes {
        multiplierUInt64 = (multiplierUInt64 << 8) + UInt64(byte)
    }
    let targetAssets = (baseAssetsUInt256 * UInt256(multiplierUInt64)) / UInt256(100000000)
    
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_erc4626_vault_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [vaultAddress, assetAddress, assetBalanceSlot, vaultTotalAssetsSlot, priceMultiplier, targetAssets]
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
    signer: Test.TestAccount
) {
    // Sort tokens (Uniswap V3 requires token0 < token1)
    let token0 = tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress
    let token1 = tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress
    let token0BalanceSlot = tokenAAddress < tokenBAddress ? tokenABalanceSlot : tokenBBalanceSlot
    let token1BalanceSlot = tokenAAddress < tokenBAddress ? tokenBBalanceSlot : tokenABalanceSlot
    
    let poolPrice = tokenAAddress < tokenBAddress ? priceTokenBPerTokenA : 1.0 / priceTokenBPerTokenA
    
    let targetSqrtPriceX96 = calculateSqrtPriceX96(price: poolPrice)
    let targetTick = calculateTick(price: poolPrice)
    
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
    
    // sqrt(price) * 2^96, adjusted for UFix64 scaling
    let sqrtPriceScaled = sqrt(n: priceScaled, scaleFactor: UInt256(1) << 48)
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
    let tick = lnPrice / ln1_0001
    
    return tick
}

/// Calculate square root using Newton's method
/// Returns sqrt(n) * scaleFactor for precision
access(self) fun sqrt(n: UInt256, scaleFactor: UInt256): UInt256 {
    if n == UInt256(0) {
        return UInt256(0)
    }
    
    var x = (n * scaleFactor) / UInt256(2)
    var prevX = UInt256(0)
    var iterations = 0
    
    while x != prevX && iterations < 50 {
        prevX = x
        let nScaled = n * scaleFactor * scaleFactor
        x = (x + nScaled / x) / UInt256(2)
        iterations = iterations + 1
    }
    
    return x
}

/// Calculate natural logarithm using Taylor series
/// Returns ln(x) * scaleFactor for precision
access(self) fun ln(x: UInt256, scaleFactor: UInt256): Int256 {
    if x == UInt256(0) {
        panic("ln(0) is undefined")
    }
    
    // Reduce x to range [0.5, 1.5] for better convergence
    var value = x
    var n = 0
    
    let threshold = (scaleFactor * UInt256(3)) / UInt256(2)
    while value > threshold {
        value = value / UInt256(2)
        n = n + 1
    }
    
    let lowerThreshold = scaleFactor / UInt256(2)
    while value < lowerThreshold {
        value = value * UInt256(2)
        n = n - 1
    }
    
    // Taylor series: ln(1+z) = z - z^2/2 + z^3/3 - ...
    let z = value > scaleFactor 
        ? Int256(value - scaleFactor)
        : -Int256(scaleFactor - value)
    
    var result = z
    var term = z
    var i = 2
    var prevResult = Int256(0)
    
    while i <= 50 && result != prevResult {
        prevResult = result
        term = (term * z) / Int256(scaleFactor)
        if i % 2 == 0 {
            result = result - term / Int256(i)
        } else {
            result = result + term / Int256(i)
        }
        i = i + 1
    }
    
    // Adjust for range reduction: ln(2^n * y) = n*ln(2) + ln(y)
    let ln2Scaled = Int256(693147180559945309) // ln(2) * 10^18
    result = result + Int256(n) * ln2Scaled
    
    return result
}
