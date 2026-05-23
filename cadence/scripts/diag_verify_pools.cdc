import "EVM"
import "FlowEVMBridgeUtils"

/// Verifies all Uniswap V3 pools required by FlowYieldVaultsStrategiesV2 on Flow EVM mainnet.
///
/// For each pool reports:
///   poolAddress            – address from factory.getPool(); zero = pool never deployed
///   exists                 – true if pool address is non-zero
///   initialized            – true if slot0.sqrtPriceX96 != 0 (initial price has been set)
///   hasLiquidity           – true if current in-range liquidity > 0
///   <tokenA>_balance       – human-readable reserve of tokenA (token units, 8 dp precision)
///   <tokenB>_balance       – human-readable reserve of tokenB (token units, 8 dp precision)
///   <tokenA>_balance_wei   – raw ERC20 reserve of tokenA in smallest unit
///   <tokenB>_balance_wei   – raw ERC20 reserve of tokenB in smallest unit
///
/// Interpretation:
///   exists=false       → pool contract was never created; must be deployed by an LP
///   initialized=false  → pool exists but no price was ever set; add initial liquidity first
///   hasLiquidity=false → pool is initialised but all LP positions are currently out of range
///   balance=0.0        → no reserves in pool; needs liquidity seeded before swaps will work
///
/// Run:
///   flow scripts execute cadence/scripts/diag_verify_pools.cdc --network mainnet
///
/// Pools checked (all Uniswap V3, factory 0xca6d7Bb03334bBf135902e1d919a5feccb461632):
///
///   ┌─ User-requested pools ─────────────────────────────────────────────────────────┐
///   │ 1. MOET   / PYUSD0   fee=100   pre-swap: PYUSD0 collateral → MOET for FlowALP  │
///   │ 2. FUSDEV / PYUSD0   fee=100   FUSDEVStrategy: yield token ↔ stablecoin        │
///   │ 3. syWFLOWv / WFLOW  fee=100   syWFLOWvStrategy: yield token ↔ WFLOW           │
///   └────────────────────────────────────────────────────────────────────────────────┘
///   ┌─ Multi-hop path pools (also required) ─────────────────────────────────────────┐
///   │ 4. PYUSD0 / WFLOW    fee=3000  FUSDEVStrategy FLOW collateral path             │
///   │ 5. PYUSD0 / WETH     fee=3000  FUSDEVStrategy WETH collateral path             │
///   │ 6. PYUSD0 / WBTC     fee=3000  FUSDEVStrategy WBTC collateral path             │
///   │ 7. WFLOW  / WETH     fee=3000  syWFLOWvStrategy WETH/WBTC collateral first hop │
///   │ 8. WETH   / WBTC     fee=3000  syWFLOWvStrategy WBTC collateral second hop     │
///   └────────────────────────────────────────────────────────────────────────────────┘
access(all) fun main(): {String: {String: AnyStruct}} {

    let factory  = EVM.addressFromString("0xca6d7Bb03334bBf135902e1d919a5feccb461632")

    // ── Token EVM addresses ────────────────────────────────────────────────────
    let moet     = EVM.addressFromString("0x213979bb8a9a86966999b3aa797c1fcf3b967ae2")
    let pyusd0   = EVM.addressFromString("0x99aF3EeA856556646C98c8B9b2548Fe815240750")
    let fusdev   = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")
    let wflow    = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e")
    let sywflowv = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let weth     = EVM.addressFromString("0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590")
    let wbtc     = EVM.addressFromString("0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579")

    // ── EVM call helper ────────────────────────────────────────────────────────
    fun call(_ to: EVM.EVMAddress, _ data: [UInt8]): EVM.Result {
        return EVM.dryCall(
            from: factory, to: to, data: data,
            gasLimit: 1_000_000, value: EVM.Balance(attoflow: 0)
        )
    }

    // ── Wei → token units (truncated to UFix64's 8 decimal places) ────────────
    fun toHuman(_ wei: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: wei, decimals: decimals)
        }
        // Floor to 8-decimal boundary before converting to avoid precision loss
        let quantum = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        return FlowEVMBridgeUtils.uint256ToUFix64(value: wei - (wei % quantum), decimals: decimals)
    }

    // ── Single-pool checker ────────────────────────────────────────────────────
    fun checkPool(
        label: String,
        tokenA: EVM.EVMAddress, tokenAName: String,
        tokenB: EVM.EVMAddress, tokenBName: String,
        fee: UInt256
    ): {String: AnyStruct} {
        var out: {String: AnyStruct} = {"label": label}

        // 1. Resolve pool address from factory
        let poolRes = call(factory, EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)", [tokenA, tokenB, fee]
        ))
        if poolRes.status != EVM.Status.successful {
            out["error"] = "getPool failed: ".concat(poolRes.errorMessage)
            return out
        }
        let poolAddr = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: poolRes.data)[0] as! EVM.EVMAddress
        let poolStr  = poolAddr.toString()
        out["poolAddress"] = poolStr

        let exists = poolStr != "0000000000000000000000000000000000000000"
        out["exists"] = exists
        if !exists {
            out["initialized"]  = false
            out["hasLiquidity"] = false
            return out
        }

        // 2. slot0() → sqrtPriceX96 (uint160 ABI-padded to 32 bytes, decoded as UInt256)
        //    non-zero means the pool was initialised with a starting price
        let slot0Res = call(poolAddr, EVM.encodeABIWithSignature("slot0()", []))
        if slot0Res.status != EVM.Status.successful {
            out["error"] = "slot0 call failed: ".concat(slot0Res.errorMessage)
            return out
        }
        let sqrtPriceX96 = EVM.decodeABI(types: [Type<UInt256>()], data: slot0Res.data)[0] as! UInt256
        out["sqrtPriceX96"] = sqrtPriceX96
        out["initialized"]  = sqrtPriceX96 != UInt256(0)

        // 3. liquidity() → current in-range liquidity (uint128, decoded as UInt256)
        let liqRes = call(poolAddr, EVM.encodeABIWithSignature("liquidity()", []))
        if liqRes.status == EVM.Status.successful {
            let liq = EVM.decodeABI(types: [Type<UInt256>()], data: liqRes.data)[0] as! UInt256
            out["liquidity"]    = liq
            out["hasLiquidity"] = liq > UInt256(0)
        }

        // 4. ERC20 decimals + balanceOf(pool) — actual reserves held in the pool contract
        let decA = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenA)
        let decB = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenB)

        let balARes = call(tokenA, EVM.encodeABIWithSignature("balanceOf(address)", [poolAddr]))
        if balARes.status == EVM.Status.successful {
            let wei = EVM.decodeABI(types: [Type<UInt256>()], data: balARes.data)[0] as! UInt256
            out[tokenAName.concat("_balance")]     = toHuman(wei, decA)
            out[tokenAName.concat("_balance_wei")] = wei
        }
        let balBRes = call(tokenB, EVM.encodeABIWithSignature("balanceOf(address)", [poolAddr]))
        if balBRes.status == EVM.Status.successful {
            let wei = EVM.decodeABI(types: [Type<UInt256>()], data: balBRes.data)[0] as! UInt256
            out[tokenBName.concat("_balance")]     = toHuman(wei, decB)
            out[tokenBName.concat("_balance_wei")] = wei
        }

        return out
    }

    // ── Run all checks ─────────────────────────────────────────────────────────
    return {
        "1_moet_pyusd0_fee100": checkPool(
            label:      "MOET / PYUSD0  fee=100  [pre-swap: PYUSD0 collateral → MOET for FlowALP]",
            tokenA:     moet,     tokenAName: "MOET",
            tokenB:     pyusd0,   tokenBName: "PYUSD0",
            fee:        UInt256(100)
        ),
        "2_fusdev_pyusd0_fee100": checkPool(
            label:      "FUSDEV / PYUSD0  fee=100  [FUSDEVStrategy: yield token ↔ stablecoin]",
            tokenA:     fusdev,   tokenAName: "FUSDEV",
            tokenB:     pyusd0,   tokenBName: "PYUSD0",
            fee:        UInt256(100)
        ),
        "3_sywflowv_wflow_fee100": checkPool(
            label:      "syWFLOWv / WFLOW  fee=100  [syWFLOWvStrategy: yield token ↔ WFLOW]",
            tokenA:     sywflowv, tokenAName: "syWFLOWv",
            tokenB:     wflow,    tokenBName: "WFLOW",
            fee:        UInt256(100)
        ),
        "4_pyusd0_wflow_fee3000": checkPool(
            label:      "PYUSD0 / WFLOW  fee=3000  [FUSDEVStrategy: FLOW collateral exit path]",
            tokenA:     pyusd0,   tokenAName: "PYUSD0",
            tokenB:     wflow,    tokenBName: "WFLOW",
            fee:        UInt256(3000)
        ),
        "5_pyusd0_weth_fee3000": checkPool(
            label:      "PYUSD0 / WETH  fee=3000  [FUSDEVStrategy: WETH collateral exit path]",
            tokenA:     pyusd0,   tokenAName: "PYUSD0",
            tokenB:     weth,     tokenBName: "WETH",
            fee:        UInt256(3000)
        ),
        "6_pyusd0_wbtc_fee3000": checkPool(
            label:      "PYUSD0 / WBTC  fee=3000  [FUSDEVStrategy: WBTC collateral exit path]",
            tokenA:     pyusd0,   tokenAName: "PYUSD0",
            tokenB:     wbtc,     tokenBName: "WBTC",
            fee:        UInt256(3000)
        ),
        "7_wflow_weth_fee3000": checkPool(
            label:      "WFLOW / WETH  fee=3000  [syWFLOWvStrategy: WETH & WBTC collateral first hop]",
            tokenA:     wflow,    tokenAName: "WFLOW",
            tokenB:     weth,     tokenBName: "WETH",
            fee:        UInt256(3000)
        ),
        "8_weth_wbtc_fee3000": checkPool(
            label:      "WETH / WBTC  fee=3000  [syWFLOWvStrategy: WBTC collateral second hop]",
            tokenA:     weth,     tokenAName: "WETH",
            tokenB:     wbtc,     tokenBName: "WBTC",
            fee:        UInt256(3000)
        )
    }
}
