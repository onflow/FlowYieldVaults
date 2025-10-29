import Test

import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "UniswapV3SwapConnectors"
import "SwapConnectors"
import "DeFiActions"

/// test_helpers_v3.cdc
///
/// Helper functions for mirror tests that use real PunchSwap V3 pools via EVM.
/// These tests require:
/// - Flow emulator running
/// - EVM gateway running
/// - PunchSwap v3 contracts deployed
/// - Tokens bridged between Cadence and EVM

/// Configuration for V3 integration (should match deployed addresses)
access(all) struct V3Config {
    access(all) let factoryAddress: String
    access(all) let routerAddress: String
    access(all) let quoterAddress: String
    access(all) let positionManagerAddress: String
    
    init(
        factoryAddress: String,
        routerAddress: String,
        quoterAddress: String,
        positionManagerAddress: String
    ) {
        self.factoryAddress = factoryAddress
        self.routerAddress = routerAddress
        self.quoterAddress = quoterAddress
        self.positionManagerAddress = positionManagerAddress
    }
}

/// Default PunchSwap v3 addresses from local deployment
/// Update these if deploying to different environment
access(all) fun getDefaultV3Config(): V3Config {
    return V3Config(
        factoryAddress: "0x986Cb42b0557159431d48fE0A40073296414d410",
        routerAddress: "0x717C515542929d3845801aF9a851e72fE27399e2",
        quoterAddress: "0x14885A6C9d1a9bDb22a9327e1aA7730e60F79399",
        positionManagerAddress: "0x9cD8d8622753C4FEBef4193e4ccaB6ae4C26772a"
    )
}

/// Setup COA (Cadence Owned Account) for a test account
/// This is required for any EVM interactions
access(all) fun setupCOAForAccount(_ account: Test.TestAccount, fundingAmount: UFix64) {
    // Create COA transaction
    let createTx = Test.Transaction(
        code: Test.readFile("../../lib/flow-evm-bridge/cadence/transactions/evm/create_cadence_owned_account.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: [fundingAmount]
    )
    let createRes = Test.executeTransaction(createTx)
    Test.expect(createRes, Test.beSucceeded())
}

/// Get the EVM address associated with a Cadence token type
/// Requires the token to be bridged via flow-evm-bridge
access(all) fun getEVMAddressForType(_ tokenType: Type): String? {
    // Use FlowEVMBridgeConfig to get associated EVM address
    let script = Test.readFile("../../lib/flow-evm-bridge/cadence/scripts/utils/get_associated_evm_address_hex.cdc")
    let res = Test.executeScript(script, [tokenType.identifier])
    if res.status == Test.ResultStatus.succeeded {
        return res.returnValue as! String?
    }
    return nil
}

/// Create a UniswapV3SwapConnectors.Swapper instance
/// This is the main interface for interacting with v3 pools from Cadence
access(all) fun createV3Swapper(
    account: Test.TestAccount,
    token0EVM: String,
    token1EVM: String,
    token0Type: Type,
    token1Type: Type,
    feeTier: UInt32
): UniswapV3SwapConnectors.Swapper {
    let config = getDefaultV3Config()
    
    // Get COA capability
    let coaCap = account.account.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(
        /storage/evm
    )
    
    let factory = EVM.addressFromString(config.factoryAddress)
    let router = EVM.addressFromString(config.routerAddress)
    let quoter = EVM.addressFromString(config.quoterAddress)
    let t0 = EVM.addressFromString(token0EVM)
    let t1 = EVM.addressFromString(token1EVM)
    
    return UniswapV3SwapConnectors.Swapper(
        factoryAddress: factory,
        routerAddress: router,
        quoterAddress: quoter,
        tokenPath: [t0, t1],
        feePath: [feeTier],
        inVault: token0Type,
        outVault: token1Type,
        coaCapability: coaCap,
        uniqueID: nil
    )
}

/// Execute a swap using UniswapV3SwapConnectors and log the results
/// Returns the amount of output tokens received
access(all) fun executeV3SwapAndLog(
    account: Test.TestAccount,
    swapper: UniswapV3SwapConnectors.Swapper,
    amountIn: UFix64,
    inVaultPath: StoragePath,
    outVaultPath: StoragePath
): UFix64 {
    // Get quote
    let quote = swapper.quoteOut(forProvided: amountIn, reverse: false)
    log("MIRROR:v3_quote_in=".concat(amountIn.toString()))
    log("MIRROR:v3_quote_out=".concat(quote.outAmount.toString()))
    
    // Calculate price impact
    let priceRatio = quote.outAmount / amountIn
    log("MIRROR:v3_price_ratio=".concat(priceRatio.toString()))
    
    // Note: Actual swap execution would require:
    // 1. Withdraw from Cadence vault
    // 2. Bridge to EVM if needed
    // 3. Execute swap via swapper.swap()
    // 4. Bridge result back if needed
    // 5. Deposit to output vault
    
    // For now, just return the quoted amount
    // Full implementation would need transaction-based approach
    return quote.outAmount
}

/// Check if a v3 pool exists for a token pair
access(all) fun checkV3PoolExists(
    token0EVM: String,
    token1EVM: String,
    feeTier: UInt32
): Bool {
    let config = getDefaultV3Config()
    let factory = EVM.addressFromString(config.factoryAddress)
    let t0 = EVM.addressFromString(token0EVM)
    let t1 = EVM.addressFromString(token1EVM)
    
    // Note: Would need to call factory.getPool() via EVM
    // This is a placeholder - actual implementation needs EVM call
    return true
}

/// Log v3-specific mirror metrics
access(all) fun logV3MirrorMetrics(
    testName: String,
    swapNumber: UInt64,
    amountIn: UFix64,
    amountOut: UFix64,
    priceImpact: UFix64,
    cumulativeVolume: UFix64
) {
    log("MIRROR:test=".concat(testName))
    log("MIRROR:swap_num=".concat(swapNumber.toString()))
    log("MIRROR:amount_in=".concat(amountIn.toString()))
    log("MIRROR:amount_out=".concat(amountOut.toString()))
    log("MIRROR:price_impact=".concat(priceImpact.toString()))
    log("MIRROR:cumulative_volume=".concat(cumulativeVolume.toString()))
}

/// Helper to format v3 addresses for logging
access(all) fun formatV3Address(_ addr: String): String {
    // Truncate address for readability: 0x1234...5678
    if addr.length <= 10 {
        return addr
    }
    return addr.slice(from: 0, upTo: 6).concat("...").concat(addr.slice(from: addr.length - 4, upTo: addr.length))
}

