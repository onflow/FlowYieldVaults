import Test
import "FlowEVMBridgeUtils"
import "EVMAmountUtils"
import "UniswapV3SwapConnectors"

access(all) let serviceAccount = Test.serviceAccount()

access(all)
fun setup() {
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "EVMAbiHelpers",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/EVMAbiHelpers.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "EVMAmountUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/EVMAmountUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "UniswapV3SwapConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/evm/UniswapV3SwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

/* --- Helpers --- */

access(all) fun toEVM(_ x: UFix64, decimals: UInt8): UInt256 {
    return FlowEVMBridgeUtils.ufix64ToUInt256(value: x, decimals: decimals)
}

access(all) fun quantum(_ decimals: UInt8): UInt256 {
    if decimals <= 8 { return UInt256(1) }
    return FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
}

access(all) let ONE_QUANTUM: UFix64 = 0.00000001

/* --- Tests --- */

/// For any 18-decimal EVM amount the gap between toCadenceIn (ceil) and
/// toCadenceOut (floor) is at most 0.00000001 (1 UFix64 quantum).
access(all) fun test_ceil_floor_gap_capped_at_one_quantum() {
    let decimals: UInt8 = 18
    let q = quantum(decimals)

    let a0: UInt256 = UInt256(1)
    let a1: UInt256 = q - UInt256(1)
    let a2: UInt256 = q + UInt256(1)
    let a3: UInt256 = UInt256(1000) * q + UInt256(1)
    let a4: UInt256 = UInt256(1000) * q + q / UInt256(2)
    let a5: UInt256 = UInt256(1000) * q + q - UInt256(1)
    let a6: UInt256 = UInt256(5000000002) * UInt256(1000000000)
    let a7: UInt256 = UInt256(12345678) * UInt256(10000000000) + UInt256(12345678)
    let a8: UInt256 = UInt256(99999999) * UInt256(10000000000) + UInt256(9999999999)

    let amounts: [UInt256] = [a0, a1, a2, a3, a4, a5, a6, a7, a8]

    for amt in amounts {
        let ceiled = EVMAmountUtils.toCadenceIn(amt, decimals: decimals)
        let floored = EVMAmountUtils.toCadenceOut(amt, decimals: decimals)
        let gap = ceiled - floored

        assert(
            gap <= ONE_QUANTUM,
            message: "Gap exceeds 0.00000001 for amount "
                .concat(amt.toString())
                .concat(": ceil=").concat(ceiled.toString())
                .concat(" floor=").concat(floored.toString())
                .concat(" gap=").concat(gap.toString())
        )
    }
}

/// Quantum-aligned amounts produce zero overshoot -- ceil equals floor.
access(all) fun test_quantum_aligned_zero_overshoot() {
    let decimals: UInt8 = 18
    let q = quantum(decimals)

    let a0: UInt256 = q
    let a1: UInt256 = UInt256(10) * q
    let a2: UInt256 = UInt256(5000000001) * q

    let aligned: [UInt256] = [a0, a1, a2]

    for amt in aligned {
        let ceiled = EVMAmountUtils.toCadenceIn(amt, decimals: decimals)
        let floored = EVMAmountUtils.toCadenceOut(amt, decimals: decimals)

        assert(
            ceiled == floored,
            message: "Quantum-aligned amount "
                .concat(amt.toString())
                .concat(" should have zero gap, got ceil=")
                .concat(ceiled.toString())
                .concat(" floor=").concat(floored.toString())
        )
    }
}

/// Reproduce the exact overshoot scenario documented in
/// UniswapV3SwapConnectors._swapExactIn (lines 506-515):
///
///   Pool price 1 FLOW = 2 USDC, want 10 USDC out.
///   1. Quoter says need  5,000000002000000000 FLOW wei
///   2. Ceil to UFix64:   5.00000001 FLOW          (overshoot 8e9 wei)
///   3. Extra input x 2 = 16e9 USDC wei extra output
///   4. Actual output:   10,000000016000000000 USDC wei
///   5. Floor to UFix64: 10.00000001 USDC          (overshoot 0.00000001)
///
access(all) fun test_documented_swap_overshoot_scenario() {
    let decimals: UInt8 = 18
    let q = quantum(decimals)

    // Step 1: quoter reports exact input needed (in wei)
    let quoterInputWei: UInt256 = UInt256(5000000002) * UInt256(1000000000)

    // Step 2: ceil to UFix64
    let ceiledInput = EVMAmountUtils.toCadenceIn(quoterInputWei, decimals: decimals)
    Test.assertEqual(5.00000001, ceiledInput)

    // Convert back to EVM -- this is the amount actually sent to the pool
    let ceiledInputEVM = toEVM(ceiledInput, decimals: decimals)
    Test.assertEqual(
        UInt256(5000000010) * UInt256(1000000000),
        ceiledInputEVM
    )

    // Input overshoot in wei
    let inputOvershoot = ceiledInputEVM - quoterInputWei
    Test.assertEqual(UInt256(8000000000), inputOvershoot)
    assert(inputOvershoot < q, message: "Input overshoot must be < 1 quantum")

    // Step 3-4: pool price 2 => extra output = 8e9 x 2 = 16e9 USDC wei
    let tenTokens: UInt256 = UInt256(10) * UInt256(1000000000) * UInt256(1000000000)
    let actualOutputWei = tenTokens + inputOvershoot * UInt256(2)

    // Step 5: floor both to UFix64
    let desiredUFix = EVMAmountUtils.toCadenceOut(tenTokens, decimals: decimals)
    let actualUFix = EVMAmountUtils.toCadenceOut(actualOutputWei, decimals: decimals)

    Test.assertEqual(10.0, desiredUFix)
    Test.assertEqual(10.00000001, actualUFix)

    // Overshoot is exactly 1 UFix64 quantum
    Test.assertEqual(ONE_QUANTUM, actualUFix - desiredUFix)
}

/// The round-trip ceil overshoot in EVM units is always strictly less than
/// 1 quantum, so the input sent to the pool exceeds the quoter amount by
/// less than 10^10 wei (< 0.00000001 in UFix64).
access(all) fun test_ceil_roundtrip_overshoot_below_one_quantum() {
    let decimals: UInt8 = 18
    let q = quantum(decimals)

    let a0: UInt256 = UInt256(1)
    let a1: UInt256 = q - UInt256(1)
    let a2: UInt256 = q + UInt256(1)
    let a3: UInt256 = UInt256(5000000002) * UInt256(1000000000)
    let a4: UInt256 = UInt256(12345678) * UInt256(10000000000) + UInt256(12345678)
    let a5: UInt256 = UInt256(99999999) * UInt256(10000000000) + UInt256(9999999999)

    let amounts: [UInt256] = [a0, a1, a2, a3, a4, a5]

    for amt in amounts {
        let ceiled = EVMAmountUtils.toCadenceIn(amt, decimals: decimals)
        let backToEVM = toEVM(ceiled, decimals: decimals)

        assert(backToEVM >= amt, message: "Ceiled round-trip must be >= original")
        assert(
            backToEVM - amt < q,
            message: "EVM overshoot must be < 1 quantum for "
                .concat(amt.toString())
                .concat(": overshoot=").concat((backToEVM - amt).toString())
        )
    }
}

/// Worst-case remainder (quantum - 1) produces exactly the maximum
/// UFix64 gap of 0.00000001, and the EVM overshoot is exactly 1 wei.
access(all) fun test_worst_case_remainder_produces_max_gap() {
    let decimals: UInt8 = 18
    let q = quantum(decimals)

    // remainder = q - 1 => maximum ceil padding
    let amt: UInt256 = UInt256(42) * q + q - UInt256(1)

    let ceiled = EVMAmountUtils.toCadenceIn(amt, decimals: decimals)
    let floored = EVMAmountUtils.toCadenceOut(amt, decimals: decimals)

    Test.assertEqual(ONE_QUANTUM, ceiled - floored)

    // EVM overshoot is exactly 1 wei -- the minimum non-zero overshoot
    let backToEVM = toEVM(ceiled, decimals: decimals)
    Test.assertEqual(UInt256(1), backToEVM - amt)
}
