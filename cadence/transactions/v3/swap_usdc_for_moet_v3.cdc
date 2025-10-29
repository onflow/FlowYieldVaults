import "FungibleToken"
import "EVM"
import "FlowEVMBridge"
import "FlowEVMBridgeUtils"
import "EVMAbiHelpers"

/// Execute a REAL swap on V3 pool (USDC → MOET)
/// This CHANGES pool state (unlike quoting)
transaction(amountInUFix: UFix64) {
    
    let coa: auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount
    let usdcVault: @{FungibleToken.Vault}
    
    prepare(signer: auth(Storage, BorrowValue, SaveValue) &Account) {
        // Get COA
        self.coa = signer.storage.borrow<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA found")
        
        // Get USDC vault from bridge
        let usdcAddr = EVM.addressFromString("0x8C7187932B862F962f1471c6E694aeFfb9F5286D")
        let usdcType = FlowEVMBridgeConfig.getTypeAssociated(with: usdcAddr)
            ?? panic("USDC not bridged")
        
        // Withdraw USDC from signer's vault
        let vaultCap = signer.capabilities.get<&{FungibleToken.Provider}>(
            /public/evmVaultProvider  // Bridged token vault path
        )
        if !vaultCap.check() {
            panic("USDC vault not accessible")
        }
        
        let provider = vaultCap.borrow() ?? panic("Cannot borrow provider")
        self.usdcVault <- provider.withdraw(amount: amountInUFix)
    }
    
    execute {
        // V3 router address
        let routerAddr = EVM.addressFromString("0x717C515542929d3845801aF9a851e72fE27399e2")
        let moetAddr = EVM.addressFromString("0x9a7b1d144828c356ec23ec862843fca4a8ff829e")
        let usdcAddr = EVM.addressFromString("0x8C7187932B862F962f1471c6E694aeFfb9F5286D")
        
        // Bridge USDC vault to EVM
        let usdcERC20 = FlowEVMBridge.bridgeTokensToEVM(
            vault: <-self.usdcVault,
            to: self.coa.address(),
            feeProvider: nil
        )
        
        // Approve router to spend USDC
        let amountInWei = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(
            amountInUFix,
            erc20Address: usdcAddr
        )
        
        let approveSelector: [UInt8] = [0x09, 0x5E, 0xA7, 0xB3]  // approve(address,uint256)
        var approveData = approveSelector
        approveData.appendAll(EVMAbiHelpers.abiAddress(routerAddr))
        approveData.appendAll(EVMAbiHelpers.abiUInt256(amountInWei))
        
        let approveResult = self.coa.call(
            to: usdcAddr,
            data: approveData,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(approveResult.status == EVM.Status.successful, message: "Approve failed")
        
        // Execute swap via router: exactInputSingle
        // function exactInputSingle(ExactInputSingleParams calldata params)
        // struct: (tokenIn, tokenOut, fee, recipient, deadline, amountIn, amountOutMinimum, sqrtPriceLimitX96)
        
        let swapSelector: [UInt8] = [0x41, 0x4B, 0xF3, 0x89]  // exactInputSingle selector
        var swapData = swapSelector
        
        // Encode struct (8 fields, all 32-byte words)
        swapData.appendAll(EVMAbiHelpers.abiAddress(usdcAddr))                    // tokenIn
        swapData.appendAll(EVMAbiHelpers.abiAddress(moetAddr))                    // tokenOut
        swapData.appendAll(EVMAbiHelpers.abiWord(UInt256(3000)))                  // fee
        swapData.appendAll(EVMAbiHelpers.abiAddress(self.coa.address()))          // recipient
        swapData.appendAll(EVMAbiHelpers.abiWord(UInt256(9999999999)))            // deadline
        swapData.appendAll(EVMAbiHelpers.abiUInt256(amountInWei))                 // amountIn
        swapData.appendAll(EVMAbiHelpers.abiWord(UInt256(0)))                     // amountOutMinimum
        swapData.appendAll(EVMAbiHelpers.abiWord(UInt256(0)))                     // sqrtPriceLimitX96
        
        let swapResult = self.coa.call(
            to: routerAddr,
            data: swapData,
            gasLimit: 1_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        
        if swapResult.status != EVM.Status.successful {
            panic("Swap failed: status=".concat(swapResult.status.rawValue.toString()))
        }
        
        // Decode amount out
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: swapResult.data)
        let amountOut = decoded[0] as! UInt256
        
        log("SWAP_EXECUTED: ".concat(amountInUFix.toString()).concat(" USDC → ").concat(amountOut.toString()).concat(" MOET (wei)"))
    }
}

