import "EVM"

// Test that Uniswap V3 Quoter can READ from vm.store'd pools (proves pools are readable)
transaction(
    quoterAddress: String,
    tokenIn: String,
    tokenOut: String,
    fee: UInt32,
    amountIn: UInt256
) {
    prepare(signer: &Account) {}

    execute {
        log("\n=== TESTING QUOTER READ (PROOF POOLS ARE READABLE) ===")
        log("Quoter: \(quoterAddress)")
        log("TokenIn: \(tokenIn)")
        log("TokenOut: \(tokenOut)")
        log("Amount: \(amountIn.toString())")
        log("Fee: \(fee)")

        let quoter = EVM.addressFromString(quoterAddress)
        let token0 = EVM.addressFromString(tokenIn)
        let token1 = EVM.addressFromString(tokenOut)

        // Build path bytes: tokenIn(20) + fee(3) + tokenOut(20)
        var pathBytes: [UInt8] = []
        let token0Bytes: [UInt8; 20] = token0.bytes
        let token1Bytes: [UInt8; 20] = token1.bytes
        var i = 0
        while i < 20 { pathBytes.append(token0Bytes[i]); i = i + 1 }
        pathBytes.append(UInt8((fee >> 16) & 0xFF))
        pathBytes.append(UInt8((fee >> 8) & 0xFF))
        pathBytes.append(UInt8(fee & 0xFF))
        i = 0
        while i < 20 { pathBytes.append(token1Bytes[i]); i = i + 1 }

        // Call quoter.quoteExactInput(path, amountIn)
        let quoteCalldata = EVM.encodeABIWithSignature("quoteExactInput(bytes,uint256)", [pathBytes, amountIn])
        let quoteResult = EVM.call(
            from: quoterAddress,
            to: quoterAddress,
            data: quoteCalldata,
            gasLimit: 2000000,
            value: 0
        )

        if quoteResult.status == EVM.Status.successful {
            let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: quoteResult.data)
            let amountOut = decoded[0] as! UInt256
            log("✓✓✓ QUOTER READ SUCCEEDED ✓✓✓")
            log("Quote result: \(amountIn.toString()) tokenIn -> \(amountOut.toString()) tokenOut")

            // Calculate slippage (for 1:1 pools, expect near-equal)
            let diff = amountOut > amountIn ? amountOut - amountIn : amountIn - amountOut
            let slippageBps = (diff * UInt256(10000)) / amountIn
            log("Slippage: \(slippageBps) bps")

            if slippageBps < UInt256(100) {
                log("✓✓✓ EXCELLENT - Pool price is 1:1 with <1% slippage ✓✓✓")
            }
        } else {
            log("❌ QUOTER READ FAILED")
            log("Error: \(quoteResult.errorMessage)")
            panic("Quoter read failed - pool state is not readable!")
        }
    }
}
