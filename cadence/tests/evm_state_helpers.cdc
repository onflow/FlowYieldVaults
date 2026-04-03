import Test
import "EVM"

/* --- ERC4626 Vault State Manipulation --- */

/// Set vault share price by manipulating totalAssets, totalSupply, and asset.balanceOf(vault)
/// priceMultiplier: share price as a multiplier (e.g. 2.0 for 2x price)
access(all) fun setVaultSharePrice(
    vaultAddress: String,
    assetAddress: String,
    assetBalanceSlot: UInt256,
    totalSupplySlot: UInt256,
    vaultTotalAssetsSlot: UInt256,
    priceMultiplier: UFix64,
    signer: Test.TestAccount
) {
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_erc4626_vault_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [vaultAddress, assetAddress, assetBalanceSlot, totalSupplySlot, vaultTotalAssetsSlot, priceMultiplier]
        )
    )
    Test.expect(result, Test.beSucceeded())
}

/* --- Uniswap V3 Pool State Manipulation --- */

/// Set Uniswap V3 pool to a specific price via EVM.store
/// Creates pool if it doesn't exist, then manipulates state
/// Price is specified as UFix128 for high precision (24 decimal places)
///
/// Example: Target FLOW price is $0.50 (1 FLOW = 0.50 PYUSD), swap should yield exactly 0.5 PYUSD per FLOW after fees
///
///   let targetPrice = 0.5  // 1 WFLOW = 0.5 PYUSD
///   let fee: UInt64 = 3000 // 0.3% fee tier
///
///   setPoolToPrice(
///       factoryAddress: factoryAddress,
///       tokenAAddress: wflowAddress,
///       tokenBAddress: pyusd0Address,
///       fee: fee,
///       // Use feeAdjustedPrice to ensure swap output equals target after fees
///       priceTokenBPerTokenA: feeAdjustedPrice(targetPrice, fee: fee, reverse: false),
///       tokenABalanceSlot: wflowBalanceSlot,
///       tokenBBalanceSlot: pyusd0BalanceSlot,
///       signer: testAccount
///   )
///   // Now swapping 100 WFLOW → exactly 50 PYUSD (fee already compensated in pool price)
access(all) fun setPoolToPrice(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix128,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256,
    signer: Test.TestAccount
) {
    let seedResult = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_uniswap_v3_pool_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [factoryAddress, tokenAAddress, tokenBAddress, fee, priceTokenBPerTokenA, tokenABalanceSlot, tokenBBalanceSlot]
        )
    )
    Test.expect(seedResult, Test.beSucceeded())
}

/* --- Fee Adjustment --- */

/// Adjust a pool price to compensate for Uniswap V3 swap fees.
///
/// When swapping on Uniswap V3, the output is reduced by the pool fee.
/// This function pre-adjusts the pool price so that swaps yield exact target amounts.
///
/// Forward (reverse: false): price / (1 - fee/1e6)
///   - Use when swapping A→B (forward direction)
///   - Inflates pool price so output after fee equals target
///   - Example: targetPrice=1.0, fee=3000 (0.3%)
///     setPoolPrice = 1.0 / 0.997 = 1.003009...
///     swapOutput = 1.003009 × 0.997 = 1.0 ✓
///
/// Reverse (reverse: true): price * (1 - fee/1e6)
///   - Use when swapping B→A (reverse direction)
///   - Deflates pool price to compensate for fee on reverse path
///   - Example: targetPrice=2.0, fee=3000 (0.3%)
///     setPoolPrice = 2.0 × 0.997 = 1.994
///     For B→A swap: output = amountIn / 1.994 × 0.997 ≈ amountIn / 2.0 ✓
///
/// Computed in UFix128 for full 24-decimal-place precision.
access(all) fun feeAdjustedPrice(_ price: UFix128, fee: UInt64, reverse: Bool): UFix128 {
    let feeRate = UFix128(fee) / 1_000_000.0
    if reverse {
        return price * (1.0 - feeRate)
    }
    return price / (1.0 - feeRate)
}
