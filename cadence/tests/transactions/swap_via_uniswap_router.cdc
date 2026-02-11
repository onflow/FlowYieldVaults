import "EVM"

// Test swap using Uniswap V3 Router (has callback built-in, no bridge registration needed)
transaction(
    routerAddress: String,
    tokenInAddress: String,
    tokenOutAddress: String,
    fee: UInt32,
    amountIn: UInt256
) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        log("\n=== TESTING SWAP WITH UNISWAP V3 ROUTER ===")
        log("Router: \(routerAddress)")
        log("TokenIn: \(tokenInAddress)")
        log("TokenOut: \(tokenOutAddress)")
        log("Amount: \(amountIn.toString())")
        log("Fee: \(fee)")

        // Get COA
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)
        let coa = coaCap.borrow() ?? panic("No COA")

        let router = EVM.addressFromString(routerAddress)
        let tokenIn = EVM.addressFromString(tokenInAddress)
        let tokenOut = EVM.addressFromString(tokenOutAddress)

        // 1. Check balance before
        let balanceBeforeCalldata = EVM.encodeABIWithSignature("balanceOf(address)", [coa.address()])
        let balBefore = coa.call(to: tokenIn, data: balanceBeforeCalldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
        let balanceU256 = EVM.decodeABI(types: [Type<UInt256>()], data: balBefore.data)[0] as! UInt256
        log("\nTokenIn balance: \(balanceU256.toString())")

        // 2. Approve router
        let approveCalldata = EVM.encodeABIWithSignature("approve(address,uint256)", [router, amountIn])
        let approveRes = coa.call(to: tokenIn, data: approveCalldata, gasLimit: 120000, value: EVM.Balance(attoflow: 0))
        assert(approveRes.status == EVM.Status.successful, message: "Approval failed")
        log("✓ Approved router to spend \(amountIn.toString())")

        // 3. Build path bytes: tokenIn(20) + fee(3) + tokenOut(20)
        var pathBytes: [UInt8] = []
        let tokenInBytes: [UInt8; 20] = tokenIn.bytes
        let tokenOutBytes: [UInt8; 20] = tokenOut.bytes
        var i = 0
        while i < 20 { pathBytes.append(tokenInBytes[i]); i = i + 1 }
        pathBytes.append(UInt8((fee >> 16) & 0xFF))
        pathBytes.append(UInt8((fee >> 8) & 0xFF))
        pathBytes.append(UInt8(fee & 0xFF))
        i = 0
        while i < 20 { pathBytes.append(tokenOutBytes[i]); i = i + 1 }

        // 4. Encode exactInput params: (bytes path, address recipient, uint256 amountIn, uint256 amountOutMin)
        // Using manual ABI encoding for the tuple
        fun abiWord(_ n: UInt256): [UInt8] {
            var bytes: [UInt8] = []
            var val = n
            var i = 0
            while i < 32 {
                bytes.insert(at: 0, UInt8(val & 0xFF))
                val = val >> 8
                i = i + 1
            }
            return bytes
        }

        fun abiAddress(_ addr: EVM.EVMAddress): [UInt8] {
            var bytes: [UInt8] = []
            var i = 0
            while i < 12 { bytes.append(0); i = i + 1 }
            let addrBytes: [UInt8; 20] = addr.bytes
            i = 0
            while i < 20 { bytes.append(addrBytes[i]); i = i + 1 }
            return bytes
        }

        // Tuple encoding: (offset to path, recipient, amountIn, amountOutMinimum)
        let tupleHeadSize = 32 * 4
        let pathLenWord = abiWord(UInt256(pathBytes.length))

        // Pad path to 32-byte boundary
        var pathPadded = pathBytes
        let paddingNeeded = (32 - pathBytes.length % 32) % 32
        var padIdx = 0
        while padIdx < paddingNeeded {
            pathPadded.append(0)
            padIdx = padIdx + 1
        }

        var head: [UInt8] = []
        head = head.concat(abiWord(UInt256(tupleHeadSize)))  // offset to path
        head = head.concat(abiAddress(coa.address()))         // recipient
        head = head.concat(abiWord(amountIn))                 // amountIn
        head = head.concat(abiWord(0))                        // amountOutMinimum (accept any)

        var tail: [UInt8] = []
        tail = tail.concat(pathLenWord)
        tail = tail.concat(pathPadded)

        // selector for exactInput((bytes,address,uint256,uint256))
        let selector: [UInt8] = [0xb8, 0x58, 0x18, 0x3f]
        let outerHead: [UInt8] = abiWord(32)  // offset to tuple
        let calldata = selector.concat(outerHead).concat(head).concat(tail)

        log("\n=== EXECUTING SWAP ===")
        let swapRes = coa.call(to: router, data: calldata, gasLimit: 5000000, value: EVM.Balance(attoflow: 0))

        log("Swap status: \(swapRes.status.rawValue)")
        log("Gas used: \(swapRes.gasUsed)")
        log("Return data length: \(swapRes.data.length)")
        log("Return data hex: \(String.encodeHex(swapRes.data))")
        log("Error code: \(swapRes.errorCode)")
        log("Error message: \(swapRes.errorMessage)")

        // Check balances after
        log("\n=== CHECKING BALANCES AFTER ===")
        let balAfter = coa.call(to: tokenIn, data: balanceBeforeCalldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
        if balAfter.status == EVM.Status.successful {
            let balanceAfter = EVM.decodeABI(types: [Type<UInt256>()], data: balAfter.data)[0] as! UInt256
            log("TokenIn balance after: \(balanceAfter.toString())")
            log("TokenIn changed: \(balanceU256 != balanceAfter) (before: \(balanceU256.toString()))")
        }

        let balOutAfter = coa.call(to: tokenOut, data: EVM.encodeABIWithSignature("balanceOf(address)", [coa.address()]), gasLimit: 100000, value: EVM.Balance(attoflow: 0))
        if balOutAfter.status == EVM.Status.successful {
            let balanceOutAfter = EVM.decodeABI(types: [Type<UInt256>()], data: balOutAfter.data)[0] as! UInt256
            log("TokenOut balance after: \(balanceOutAfter.toString())")
        }

        if swapRes.status == EVM.Status.successful && swapRes.data.length >= 32 {
            let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: swapRes.data)
            let amountOut = decoded[0] as! UInt256
            log("✓✓✓ SWAP SUCCEEDED ✓✓✓")
            log("Amount out: \(amountOut.toString())")

            // Calculate slippage
            let slippagePct = amountIn > amountOut
                ? ((amountIn - amountOut) * 10000 / amountIn)
                : ((amountOut - amountIn) * 10000 / amountIn)
            log("Slippage: \(slippagePct) bps (\((UFix64(slippagePct) / 100.0))%)")

            if slippagePct < 100 {  // < 1%
                log("✓✓✓ EXCELLENT - Near-zero slippage! ✓✓✓")
            } else if slippagePct < 500 {  // < 5%
                log("✓ ACCEPTABLE - Low slippage")
            } else {
                log("⚠ HIGH SLIPPAGE")
            }
        } else {
            log("❌ SWAP FAILED")
            log("Error code: \(swapRes.errorCode)")
            log("Error: \(swapRes.errorMessage)")
        }
    }
}
