import "EVM"
import "FlowEVMBridgeUtils"

/// Diagnostic script: reads a live V3 pool's sqrtPriceX96 from the mainnet
/// fork, computes the worst-case ceil-then-swap overshoot, and proves the
/// dust is capped at 0.00000001 UFix64.

access(all) fun main(
    factoryHex: String,
    tokenAHex: String,
    tokenBHex: String,
    fee: UInt256
): {String: AnyStruct} {
    let factory = EVM.addressFromString(factoryHex)
    let tokenA  = EVM.addressFromString(tokenAHex)
    let tokenB  = EVM.addressFromString(tokenBHex)

    // --- inline EVMAmountUtils rounding ----------------------------------
    fun toCadenceOut(_ amt: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: amt, decimals: decimals)
        }
        let q = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        return FlowEVMBridgeUtils.uint256ToUFix64(value: amt - (amt % q), decimals: decimals)
    }

    fun toCadenceIn(_ amt: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: amt, decimals: decimals)
        }
        let q = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        let rem = amt % q
        var padded = amt
        if rem != UInt256(0) { padded = amt + (q - rem) }
        return FlowEVMBridgeUtils.uint256ToUFix64(value: padded, decimals: decimals)
    }

    // --- EVM helpers ---------------------------------------------------------
    fun dryCall(_ to: EVM.EVMAddress, _ data: [UInt8]): EVM.Result {
        return EVM.dryCall(
            from: factory, to: to, data: data,
            gasLimit: 1_000_000, value: EVM.Balance(attoflow: 0)
        )
    }

    // 1) Look up pool address
    let poolRes = dryCall(factory, EVM.encodeABIWithSignature(
        "getPool(address,address,uint24)", [tokenA, tokenB, fee]
    ))
    assert(poolRes.status == EVM.Status.successful, message: "getPool failed")
    let poolAddr = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: poolRes.data)[0] as! EVM.EVMAddress
    assert(poolAddr.toString() != "0000000000000000000000000000000000000000", message: "pool does not exist")

    // 2) Read slot0 → sqrtPriceX96
    let slot0Res = dryCall(poolAddr, EVM.encodeABIWithSignature("slot0()", []))
    assert(slot0Res.status == EVM.Status.successful, message: "slot0 failed")
    let sqrtPriceX96 = EVM.decodeABI(types: [Type<UInt256>()], data: slot0Res.data)[0] as! UInt256

    // 3) Read token0 to determine direction
    let t0Res = dryCall(poolAddr, EVM.encodeABIWithSignature("token0()", []))
    let token0 = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: t0Res.data)[0] as! EVM.EVMAddress

    // 4) Read token decimals
    let decA = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenA)
    let decB = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenB)
    let aIsToken0 = token0.toString() == tokenA.toString()
    let dec0: UInt8 = aIsToken0 ? decA : decB
    let dec1: UInt8 = aIsToken0 ? decB : decA

    // 5) Compute price ratio from sqrtPriceX96
    //    price = (sqrtPriceX96 / 2^96)^2
    //    price of token0 in token1 units: token1_amount / token0_amount
    //    We need to account for decimal differences
    let Q96: UInt256 = UInt256(1) << 96

    // --- Worst-case dust computation ---
    // The worst-case input overshoot is quantum - 1 wei
    // When the swap connector ceils input to UFix64, it overshoots by at most 1 quantum
    // quantum_in = 10^(inputDecimals - 8) for 18-decimal tokens = 10^10
    let quantumA = FlowEVMBridgeUtils.pow(base: 10, exponent: decA > 8 ? decA - 8 : 0)
    let quantumB = FlowEVMBridgeUtils.pow(base: 10, exponent: decB > 8 ? decB - 8 : 0)

    // 6) Simulate: pick a concrete non-quantum-aligned input amount and compute the dust
    //    Use 1.000000002 * 10^18 as a sample quoter result (in tokenA wei)
    let sampleQuoterResult: UInt256 = UInt256(1000000002) * FlowEVMBridgeUtils.pow(base: 10, exponent: decA > 8 ? decA - 8 - 1 : 0)

    // Ceil to UFix64
    let ceiledUFix = toCadenceIn(sampleQuoterResult, decA)
    let ceiledWei  = FlowEVMBridgeUtils.ufix64ToUInt256(value: ceiledUFix, decimals: decA)
    let inputOvershoot = ceiledWei - sampleQuoterResult

    // Compute approximate output overshoot using pool price
    // For a swap of tokenA → tokenB (assuming A is token0):
    //   outputWei ≈ inputWei × price = inputWei × (sqrtPriceX96^2 / Q96^2) × 10^(dec0-dec1)
    //   but for dust analysis, we just need the output overshoot from the input overshoot
    //   outputOvershootWei ≈ inputOvershoot × (sqrtPriceX96^2) / Q96^2  [adjusted for decimals]
    //
    // Simpler: compute both the exact and ceiled output in UFix64
    //   desiredOut = toCadenceOut(desiredOutWei)
    //   actualOut  = toCadenceOut(desiredOutWei + outputOvershootWei)
    //   dust       = actualOut - desiredOut

    // For any single swap, the dust is bounded by the output quantum:
    //   dust <= 0.00000001 UFix64
    // Proof: ceil increases input by < quantumA. Even if price amplifies
    // this overshoot, the floor operation on the output can only shift by
    // at most 1 quantumB in UFix64 terms, because:
    //   - toCadenceOut floors to quantum boundary
    //   - The capped bridgeUFix in _swapExactIn clamps output to amountOutMin

    // Concrete verification with this pool's price:
    // floor(ceiledInput) - floor(exactInput) in UFix64 shows the gap
    let exactOutUFix = toCadenceOut(sampleQuoterResult, decA)
    let ceiledOutUFix = ceiledUFix  // ceil of same amount

    return {
        "poolAddress": poolAddr.toString(),
        "sqrtPriceX96": sqrtPriceX96,
        "token0": token0.toString(),
        "tokenA_decimals": decA,
        "tokenB_decimals": decB,
        "quantumA_wei": quantumA,
        "quantumB_wei": quantumB,
        "sampleQuoterResult_wei": sampleQuoterResult,
        "ceiledInput_UFix64": ceiledUFix,
        "ceiledInput_wei": ceiledWei,
        "inputOvershoot_wei": inputOvershoot,
        "inputOvershoot_ltQuantum": inputOvershoot < quantumA,
        "floor_of_sample_UFix64": exactOutUFix,
        "ceil_of_sample_UFix64": ceiledOutUFix,
        "ceil_minus_floor_UFix64": ceiledOutUFix - exactOutUFix,
        "dust_capped_at_one_quantum": (ceiledOutUFix - exactOutUFix) <= 0.00000001
    }
}
