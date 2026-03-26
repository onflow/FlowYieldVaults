import "EVM"
import "FlowEVMBridgeUtils"
import "EVMAbiHelpers"
import "EVMAmountUtils"

/// Returns executable health data for a list of FlowSwap V3 pools deployed on Flow EVM.
///
/// This script is intended for monitoring pools that matter to FYV execution quality.
/// For each pool it reports whether there is current in-range liquidity, plus quoted
/// execution prices for a small probe trade and for a canonical trade size.
///
/// The script does NOT use `balanceOf(pool)`, because raw ERC20 balances are misleading
/// for concentrated-liquidity pools: they include inactive out-of-range inventory and do
/// not describe currently executable depth around the active tick.
///
/// Instead, for each pool it:
///   1. resolves the pool address from the factory
///   2. checks `pool.liquidity()` to detect whether any in-range liquidity exists
///   3. quotes exact-input swaps in both directions via the FlowSwap V3 quoter:
///      - a small probe trade (`min($10, canonicalTradeUsd)`) to approximate near-current execution
///      - a canonical trade size (`canonicalTradeUsd`) to measure route quality at a meaningful notional
///   4. marks the pool healthy only when both directions quote successfully and the
///      canonical-trade impact stays within `maxImpactBps`
///
/// Token USD prices are supplied by the caller only so the script can size quotes using
/// a fixed USD notional across very different assets. The script does not compare against
/// any external oracle or fair-value reference.
access(all) struct PoolHealth {
    access(all) let pool:                   String
    access(all) let poolAddress:            String
    access(all) let tokenA:                 String
    access(all) let tokenB:                 String
    access(all) let poolLookupSucceeded:    Bool
    access(all) let poolExists:             Bool
    access(all) let liquidityCallSucceeded: Bool
    access(all) let hasInRangeLiquidity:    Bool
    access(all) let hasTokenMetadata:       Bool
    access(all) let probeTradeUsd:          UFix64
    access(all) let canonicalTradeUsd:      UFix64
    access(all) let maxImpactBps:           UFix64
    access(all) let probeSellPriceBPerA:    UFix64
    access(all) let canonicalSellPriceBPerA: UFix64
    access(all) let hasSellQuote:           Bool
    access(all) let sellImpactBps:          UFix64
    access(all) let sellWithinImpactLimit:  Bool
    access(all) let probeBuyPriceBPerA:     UFix64
    access(all) let canonicalBuyPriceBPerA: UFix64
    access(all) let hasBuyQuote:            Bool
    access(all) let buyImpactBps:           UFix64
    access(all) let buyWithinImpactLimit:   Bool
    access(all) let healthyForExecution:    Bool

    init(
        pool: String,
        poolAddress: String,
        tokenA: String,
        tokenB: String,
        poolLookupSucceeded: Bool,
        poolExists: Bool,
        liquidityCallSucceeded: Bool,
        hasInRangeLiquidity: Bool,
        hasTokenMetadata: Bool,
        probeTradeUsd: UFix64,
        canonicalTradeUsd: UFix64,
        maxImpactBps: UFix64,
        probeSellPriceBPerA: UFix64,
        canonicalSellPriceBPerA: UFix64,
        hasSellQuote: Bool,
        sellImpactBps: UFix64,
        sellWithinImpactLimit: Bool,
        probeBuyPriceBPerA: UFix64,
        canonicalBuyPriceBPerA: UFix64,
        hasBuyQuote: Bool,
        buyImpactBps: UFix64,
        buyWithinImpactLimit: Bool,
        healthyForExecution: Bool
    ) {
        self.pool = pool
        self.poolAddress = poolAddress
        self.tokenA = tokenA
        self.tokenB = tokenB
        self.poolLookupSucceeded = poolLookupSucceeded
        self.poolExists = poolExists
        self.liquidityCallSucceeded = liquidityCallSucceeded
        self.hasInRangeLiquidity = hasInRangeLiquidity
        self.hasTokenMetadata = hasTokenMetadata
        self.probeTradeUsd = probeTradeUsd
        self.canonicalTradeUsd = canonicalTradeUsd
        self.maxImpactBps = maxImpactBps
        self.probeSellPriceBPerA = probeSellPriceBPerA
        self.canonicalSellPriceBPerA = canonicalSellPriceBPerA
        self.hasSellQuote = hasSellQuote
        self.sellImpactBps = sellImpactBps
        self.sellWithinImpactLimit = sellWithinImpactLimit
        self.probeBuyPriceBPerA = probeBuyPriceBPerA
        self.canonicalBuyPriceBPerA = canonicalBuyPriceBPerA
        self.hasBuyQuote = hasBuyQuote
        self.buyImpactBps = buyImpactBps
        self.buyWithinImpactLimit = buyWithinImpactLimit
        self.healthyForExecution = healthyForExecution
    }
}

access(all) fun main(
    factoryHex: String,
    quoterHex: String,
    poolNames: [String],
    tokenAAddrs: [String],
    tokenANames: [String],
    tokenBAddrs: [String],
    tokenBNames: [String],
    fees: [UInt64],
    tokenAUsdPrices: [UFix64],
    tokenBUsdPrices: [UFix64],
    canonicalTradeUsd: UFix64,
    maxImpactBps: UFix64
): [PoolHealth] {
    assert(poolNames.length == tokenAAddrs.length, message: "poolNames/tokenAAddrs length mismatch")
    assert(poolNames.length == tokenANames.length, message: "poolNames/tokenANames length mismatch")
    assert(poolNames.length == tokenBAddrs.length, message: "poolNames/tokenBAddrs length mismatch")
    assert(poolNames.length == tokenBNames.length, message: "poolNames/tokenBNames length mismatch")
    assert(poolNames.length == fees.length, message: "poolNames/fees length mismatch")
    assert(poolNames.length == tokenAUsdPrices.length, message: "poolNames/tokenAUsdPrices length mismatch")
    assert(poolNames.length == tokenBUsdPrices.length, message: "poolNames/tokenBUsdPrices length mismatch")
    assert(canonicalTradeUsd > 0.0, message: "canonicalTradeUsd must be > 0")
    assert(maxImpactBps >= 0.0, message: "maxImpactBps must be >= 0")

    let factory = EVM.addressFromString(factoryHex)
    let quoter = EVM.addressFromString(quoterHex)
    let probeTradeUsd = canonicalTradeUsd > 10.0 ? 10.0 : canonicalTradeUsd

    fun dryCall(_ to: EVM.EVMAddress, _ data: [UInt8]): EVM.Result {
        return EVM.dryCall(
            from: factory,
            to: to,
            data: data,
            gasLimit: 1_000_000,
            value: EVM.Balance(attoflow: 0)
        )
    }

    fun emptyResult(
        at index: Int,
        poolAddress: String,
        poolLookupSucceeded: Bool,
        poolExists: Bool,
        liquidityCallSucceeded: Bool,
        hasInRangeLiquidity: Bool,
        hasTokenMetadata: Bool
    ): PoolHealth {
        return PoolHealth(
            pool: poolNames[index],
            poolAddress: poolAddress,
            tokenA: tokenANames[index],
            tokenB: tokenBNames[index],
            poolLookupSucceeded: poolLookupSucceeded,
            poolExists: poolExists,
            liquidityCallSucceeded: liquidityCallSucceeded,
            hasInRangeLiquidity: hasInRangeLiquidity,
            hasTokenMetadata: hasTokenMetadata,
            probeTradeUsd: probeTradeUsd,
            canonicalTradeUsd: canonicalTradeUsd,
            maxImpactBps: maxImpactBps,
            probeSellPriceBPerA: 0.0,
            canonicalSellPriceBPerA: 0.0,
            hasSellQuote: false,
            sellImpactBps: 0.0,
            sellWithinImpactLimit: false,
            probeBuyPriceBPerA: 0.0,
            canonicalBuyPriceBPerA: 0.0,
            hasBuyQuote: false,
            buyImpactBps: 0.0,
            buyWithinImpactLimit: false,
            healthyForExecution: false
        )
    }

    fun buildSingleHopPath(tokenIn: EVM.EVMAddress, fee: UInt64, tokenOut: EVM.EVMAddress): EVM.EVMBytes {
        pre {
            fee <= 0xFFFFFF: "fee exceeds uint24"
        }
        return EVM.EVMBytes(
            value: EVMAbiHelpers.concat([
                EVMAbiHelpers.toVarBytes(tokenIn),
                EVMAbiHelpers.beBytesN(UInt256(fee), 3),
                EVMAbiHelpers.toVarBytes(tokenOut)
            ])
        )
    }

    fun quoteExactInput(
        tokenIn: EVM.EVMAddress,
        fee: UInt64,
        tokenOut: EVM.EVMAddress,
        amountIn: UInt256
    ): UInt256? {
        if amountIn == 0 {
            return nil
        }

        let path = buildSingleHopPath(tokenIn: tokenIn, fee: fee, tokenOut: tokenOut)
        let res = dryCall(
            quoter,
            EVM.encodeABIWithSignature(
                "quoteExactInput(bytes,uint256)",
                [path, amountIn]
            )
        )

        if res.status != EVM.Status.successful {
            return nil
        }

        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: res.data)
        if decoded.length == 0 {
            return nil
        }
        return decoded[0] as! UInt256
    }

    fun getTokenDecimalsSafe(evmContractAddress: EVM.EVMAddress): UInt8? {
        let res = dryCall(evmContractAddress, EVM.encodeABIWithSignature("decimals()", []))
        if res.status != EVM.Status.successful {
            return nil
        }

        let decoded = EVM.decodeABI(types: [Type<UInt8>()], data: res.data)
        if decoded.length == 0 {
            return nil
        }
        return decoded[0] as! UInt8
    }

    fun toTokenAmount(usdAmount: UFix64, usdPrice: UFix64): UFix64 {
        if usdAmount == 0.0 || usdPrice == 0.0 {
            return 0.0
        }
        return usdAmount / usdPrice
    }

    fun sellPriceBPerA(inputA: UFix64, outputB: UFix64): UFix64 {
        if inputA == 0.0 || outputB == 0.0 {
            return 0.0
        }
        return outputB / inputA
    }

    fun buyPriceBPerA(inputB: UFix64, outputA: UFix64): UFix64 {
        if inputB == 0.0 || outputA == 0.0 {
            return 0.0
        }
        return inputB / outputA
    }

    fun impactBps(canonical: UFix64, probe: UFix64): UFix64 {
        if canonical == 0.0 || probe == 0.0 {
            return 0.0
        }
        let diff = canonical > probe ? canonical - probe : probe - canonical
        return (diff / probe) * 10000.0
    }

    var results: [PoolHealth] = []

    var i = 0
    while i < poolNames.length {
        let tokenA = EVM.addressFromString(tokenAAddrs[i])
        let tokenB = EVM.addressFromString(tokenBAddrs[i])
        let fee = fees[i]

        // 1. Resolve pool address
        let poolRes = dryCall(
            factory,
            EVM.encodeABIWithSignature("getPool(address,address,uint24)", [tokenA, tokenB, UInt256(fee)])
        )
        if poolRes.status != EVM.Status.successful {
            results.append(
                emptyResult(
                    at: i,
                    poolAddress: "",
                    poolLookupSucceeded: false,
                    poolExists: false,
                    liquidityCallSucceeded: false,
                    hasInRangeLiquidity: false,
                    hasTokenMetadata: false
                )
            )
            i = i + 1
            continue
        }

        let poolAddr = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: poolRes.data)[0] as! EVM.EVMAddress
        let poolAddress = poolAddr.toString()
        let poolExists = poolAddress != "0000000000000000000000000000000000000000"
        if !poolExists {
            results.append(
                emptyResult(
                    at: i,
                    poolAddress: poolAddress,
                    poolLookupSucceeded: true,
                    poolExists: false,
                    liquidityCallSucceeded: false,
                    hasInRangeLiquidity: false,
                    hasTokenMetadata: false
                )
            )
            i = i + 1
            continue
        }

        // 2. Current in-range liquidity signal
        var hasInRangeLiquidity = false
        var liquidityCallSucceeded = false
        let liqRes = dryCall(poolAddr, EVM.encodeABIWithSignature("liquidity()", []))
        if liqRes.status == EVM.Status.successful {
            liquidityCallSucceeded = true
            let liq = EVM.decodeABI(types: [Type<UInt256>()], data: liqRes.data)[0] as! UInt256
            hasInRangeLiquidity = liq > 0
        }

        let tokenADecimalsOpt = getTokenDecimalsSafe(evmContractAddress: tokenA)
        let tokenBDecimalsOpt = getTokenDecimalsSafe(evmContractAddress: tokenB)
        let hasTokenMetadata = tokenADecimalsOpt != nil && tokenBDecimalsOpt != nil
        if !hasTokenMetadata {
            results.append(
                emptyResult(
                    at: i,
                    poolAddress: poolAddress,
                    poolLookupSucceeded: true,
                    poolExists: true,
                    liquidityCallSucceeded: liquidityCallSucceeded,
                    hasInRangeLiquidity: hasInRangeLiquidity,
                    hasTokenMetadata: false
                )
            )
            i = i + 1
            continue
        }

        let tokenADecimals = tokenADecimalsOpt!
        let tokenBDecimals = tokenBDecimalsOpt!

        // 3. Canonical quote sizes derived from USD notionals
        let probeAIn = toTokenAmount(usdAmount: probeTradeUsd, usdPrice: tokenAUsdPrices[i])
        let probeBIn = toTokenAmount(usdAmount: probeTradeUsd, usdPrice: tokenBUsdPrices[i])
        let canonicalAIn = toTokenAmount(usdAmount: canonicalTradeUsd, usdPrice: tokenAUsdPrices[i])
        let canonicalBIn = toTokenAmount(usdAmount: canonicalTradeUsd, usdPrice: tokenBUsdPrices[i])

        let probeAInWei = FlowEVMBridgeUtils.ufix64ToUInt256(value: probeAIn, decimals: tokenADecimals)
        let probeBInWei = FlowEVMBridgeUtils.ufix64ToUInt256(value: probeBIn, decimals: tokenBDecimals)
        let canonicalAInWei = FlowEVMBridgeUtils.ufix64ToUInt256(value: canonicalAIn, decimals: tokenADecimals)
        let canonicalBInWei = FlowEVMBridgeUtils.ufix64ToUInt256(value: canonicalBIn, decimals: tokenBDecimals)

        // 4. Sell-side quotes: tokenA -> tokenB (tokenB per tokenA)
        var probeSellPrice = 0.0
        var canonicalSellPrice = 0.0
        if let probeSellOutWei = quoteExactInput(tokenIn: tokenA, fee: fee, tokenOut: tokenB, amountIn: probeAInWei) {
            let probeSellOut = EVMAmountUtils.toCadenceOut(probeSellOutWei, decimals: tokenBDecimals)
            probeSellPrice = sellPriceBPerA(inputA: probeAIn, outputB: probeSellOut)
        }
        if let canonicalSellOutWei = quoteExactInput(tokenIn: tokenA, fee: fee, tokenOut: tokenB, amountIn: canonicalAInWei) {
            let canonicalSellOut = EVMAmountUtils.toCadenceOut(canonicalSellOutWei, decimals: tokenBDecimals)
            canonicalSellPrice = sellPriceBPerA(inputA: canonicalAIn, outputB: canonicalSellOut)
        }
        let hasSellQuote = probeSellPrice > 0.0 && canonicalSellPrice > 0.0

        // 5. Buy-side quotes: tokenB -> tokenA, normalized back to tokenB per tokenA
        var probeBuyPrice = 0.0
        var canonicalBuyPrice = 0.0
        if let probeBuyOutWei = quoteExactInput(tokenIn: tokenB, fee: fee, tokenOut: tokenA, amountIn: probeBInWei) {
            let probeBuyOut = EVMAmountUtils.toCadenceOut(probeBuyOutWei, decimals: tokenADecimals)
            probeBuyPrice = buyPriceBPerA(inputB: probeBIn, outputA: probeBuyOut)
        }
        if let canonicalBuyOutWei = quoteExactInput(tokenIn: tokenB, fee: fee, tokenOut: tokenA, amountIn: canonicalBInWei) {
            let canonicalBuyOut = EVMAmountUtils.toCadenceOut(canonicalBuyOutWei, decimals: tokenADecimals)
            canonicalBuyPrice = buyPriceBPerA(inputB: canonicalBIn, outputA: canonicalBuyOut)
        }
        let hasBuyQuote = probeBuyPrice > 0.0 && canonicalBuyPrice > 0.0

        let sellImpactBps = impactBps(canonical: canonicalSellPrice, probe: probeSellPrice)
        let buyImpactBps = impactBps(canonical: canonicalBuyPrice, probe: probeBuyPrice)
        let sellWithinImpactLimit = hasSellQuote && sellImpactBps <= maxImpactBps
        let buyWithinImpactLimit = hasBuyQuote && buyImpactBps <= maxImpactBps
        let healthyForExecution =
            poolExists
            && liquidityCallSucceeded
            && hasInRangeLiquidity
            && hasTokenMetadata
            && hasSellQuote
            && hasBuyQuote
            && sellWithinImpactLimit
            && buyWithinImpactLimit

        results.append(
            PoolHealth(
                pool: poolNames[i],
                poolAddress: poolAddress,
                tokenA: tokenANames[i],
                tokenB: tokenBNames[i],
                poolLookupSucceeded: true,
                poolExists: true,
                liquidityCallSucceeded: liquidityCallSucceeded,
                hasInRangeLiquidity: hasInRangeLiquidity,
                hasTokenMetadata: hasTokenMetadata,
                probeTradeUsd: probeTradeUsd,
                canonicalTradeUsd: canonicalTradeUsd,
                maxImpactBps: maxImpactBps,
                probeSellPriceBPerA: probeSellPrice,
                canonicalSellPriceBPerA: canonicalSellPrice,
                hasSellQuote: hasSellQuote,
                sellImpactBps: sellImpactBps,
                sellWithinImpactLimit: sellWithinImpactLimit,
                probeBuyPriceBPerA: probeBuyPrice,
                canonicalBuyPriceBPerA: canonicalBuyPrice,
                hasBuyQuote: hasBuyQuote,
                buyImpactBps: buyImpactBps,
                buyWithinImpactLimit: buyWithinImpactLimit,
                healthyForExecution: healthyForExecution
            )
        )

        i = i + 1
    }

    return results
}
