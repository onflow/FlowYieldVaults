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
            arguments: [factoryAddress, tokenAAddress, tokenBAddress, fee, priceTokenBPerTokenA, tokenABalanceSlot, tokenBBalanceSlot, 0.0, 0.0, 1.0]
        )
    )
    Test.expect(seedResult, Test.beSucceeded())
}

/// Set Uniswap V3 pool to a specific price with finite TVL and concentrated liquidity.
/// tvl: total pool TVL in USD (e.g. 10_000_000.0 for $10M)
/// concentration: fraction 0.0-1.0 (e.g. 0.80 for 80% of liquidity in narrow range)
/// tokenBPriceUSD: USD price of tokenB (e.g. 1.0 for stablecoins)
access(all) fun setPoolToPriceWithTVL(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix128,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256,
    tvl: UFix64,
    concentration: UFix64,
    tokenBPriceUSD: UFix64,
    signer: Test.TestAccount
) {
    let seedResult = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_uniswap_v3_pool_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [factoryAddress, tokenAAddress, tokenBAddress, fee, priceTokenBPerTokenA, tokenABalanceSlot, tokenBBalanceSlot, tvl, concentration, tokenBPriceUSD]
        )
    )
    Test.expect(seedResult, Test.beSucceeded())
}

/* --- Fee Adjustment --- */

/// Adjust a pool price to compensate for Uniswap V3 swap fees.
/// Forward: price / (1 - fee/1e6)
/// Reverse: price * (1 - fee/1e6)
/// Computed in UFix128 for full 24-decimal-place precision.
access(all) fun feeAdjustedPrice(_ price: UFix128, fee: UInt64, reverse: Bool): UFix128 {
    let feeRate = UFix128(fee) / 1_000_000.0
    if reverse {
        return price * (1.0 - feeRate)
    }
    return price / (1.0 - feeRate)
}
