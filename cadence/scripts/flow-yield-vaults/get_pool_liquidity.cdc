import "EVM"
import "FlowEVMBridgeUtils"

/// Returns liquidity status for a list of Uniswap V3 pools deployed on Flow EVM.
///
/// This script is called by the fcm-observer service (github.com/onflow/fcm-observer)
/// on a periodic basis to monitor pool health. The caller reads pool configuration
/// from the observer's fcm_config.json (the top-level "flowEVM" section) and passes
/// it in as arguments on each invocation.
///
/// For each pool the script resolves the pool address via the factory, then performs
/// three dry EVM calls (no gas cost):
///   1. factory.getPool(tokenA, tokenB, fee)  – resolve pool address
///   2. pool.liquidity()                       – check in-range liquidity
///   3. tokenA/tokenB.balanceOf(pool)          – read actual token reserves
///
/// If any call fails the pool entry is still returned with zero balances and
/// hasLiquidity=false, so the metric is always present (never absent/stale).
///
/// Each pool in the response contains:
///   pool         – short human-readable name supplied by the caller (e.g. "moet_pyusd0")
///   tokenA       – token A name supplied by the caller (e.g. "MOET")
///   balanceA     – token A reserve held by the pool contract (UFix64, 8 decimal places)
///   tokenB       – token B name supplied by the caller (e.g. "PYUSD0")
///   balanceB     – token B reserve held by the pool contract (UFix64, 8 decimal places)
///   hasLiquidity – true when the pool's current in-range liquidity > 0
///
/// Arguments are passed as parallel arrays (one entry per pool) rather than an array
/// of structs because Cadence scripts cannot accept arrays of structs as arguments.
/// The caller is responsible for keeping all arrays the same length and in the same order.
access(all) struct PoolStatus {
    access(all) let pool:         String
    access(all) let tokenA:       String
    access(all) let balanceA:     UFix64
    access(all) let tokenB:       String
    access(all) let balanceB:     UFix64
    access(all) let hasLiquidity: Bool

    init(
        pool:         String,
        tokenA:       String,
        balanceA:     UFix64,
        tokenB:       String,
        balanceB:     UFix64,
        hasLiquidity: Bool
    ) {
        self.pool         = pool
        self.tokenA       = tokenA
        self.balanceA     = balanceA
        self.tokenB       = tokenB
        self.balanceB     = balanceB
        self.hasLiquidity = hasLiquidity
    }
}

access(all) fun main(
    factoryHex:  String,
    poolNames:   [String],
    tokenAAddrs: [String],
    tokenANames: [String],
    tokenBAddrs: [String],
    tokenBNames: [String],
    fees:        [UInt64]
): [PoolStatus] {
    let factory = EVM.addressFromString(factoryHex)

    fun dryCall(_ to: EVM.EVMAddress, _ data: [UInt8]): EVM.Result {
        return EVM.dryCall(
            from: factory,
            to:   to,
            data: data,
            gasLimit: 1_000_000,
            value: EVM.Balance(attoflow: 0)
        )
    }

    // Floor a wei UInt256 to 8 decimal places and convert to UFix64.
    fun toHuman(_ wei: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: wei, decimals: decimals)
        }
        let quantum = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        return FlowEVMBridgeUtils.uint256ToUFix64(value: wei - (wei % quantum), decimals: decimals)
    }

    var results: [PoolStatus] = []

    var i = 0
    while i < poolNames.length {
        let tokenA = EVM.addressFromString(tokenAAddrs[i])
        let tokenB = EVM.addressFromString(tokenBAddrs[i])
        let fee    = UInt256(fees[i])

        // 1. Resolve pool address from factory.getPool(tokenA, tokenB, fee)
        let poolRes = dryCall(factory, EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)", [tokenA, tokenB, fee]
        ))
        if poolRes.status != EVM.Status.successful {
            results.append(PoolStatus(
                pool: poolNames[i], tokenA: tokenANames[i], balanceA: 0.0,
                tokenB: tokenBNames[i], balanceB: 0.0, hasLiquidity: false
            ))
            i = i + 1
            continue
        }

        let poolAddr = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: poolRes.data)[0] as! EVM.EVMAddress
        let poolStr  = poolAddr.toString()
        let exists   = poolStr != "0000000000000000000000000000000000000000"
        if !exists {
            results.append(PoolStatus(
                pool: poolNames[i], tokenA: tokenANames[i], balanceA: 0.0,
                tokenB: tokenBNames[i], balanceB: 0.0, hasLiquidity: false
            ))
            i = i + 1
            continue
        }

        // 2. liquidity() — current in-range liquidity (uint128 decoded as UInt256)
        var hasLiquidity = false
        let liqRes = dryCall(poolAddr, EVM.encodeABIWithSignature("liquidity()", []))
        if liqRes.status == EVM.Status.successful {
            let liq = EVM.decodeABI(types: [Type<UInt256>()], data: liqRes.data)[0] as! UInt256
            hasLiquidity = liq > UInt256(0)
        }

        // 3. ERC20 balanceOf(pool) for each token — actual reserves
        let decA = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenA)
        let decB = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenB)

        var balanceA: UFix64 = 0.0
        let balARes = dryCall(tokenA, EVM.encodeABIWithSignature("balanceOf(address)", [poolAddr]))
        if balARes.status == EVM.Status.successful {
            let wei = EVM.decodeABI(types: [Type<UInt256>()], data: balARes.data)[0] as! UInt256
            balanceA = toHuman(wei, decA)
        }

        var balanceB: UFix64 = 0.0
        let balBRes = dryCall(tokenB, EVM.encodeABIWithSignature("balanceOf(address)", [poolAddr]))
        if balBRes.status == EVM.Status.successful {
            let wei = EVM.decodeABI(types: [Type<UInt256>()], data: balBRes.data)[0] as! UInt256
            balanceB = toHuman(wei, decB)
        }

        results.append(PoolStatus(
            pool:         poolNames[i],
            tokenA:       tokenANames[i],
            balanceA:     balanceA,
            tokenB:       tokenBNames[i],
            balanceB:     balanceB,
            hasLiquidity: hasLiquidity
        ))

        i = i + 1
    }

    return results
}
