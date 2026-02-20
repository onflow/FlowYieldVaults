import Test
import "EVM"

/* --- ERC4626 Vault State Manipulation --- */

/// Set vault share price by setting totalAssets to a specific base value, then multiplying by the price multiplier
/// Manipulates both asset.balanceOf(vault) and vault._totalAssets to bypass maxRate capping
/// Caller should provide baseAssets large enough to prevent slippage during price changes
access(all) fun setVaultSharePrice(
    vaultAddress: String,
    assetAddress: String,
    assetBalanceSlot: UInt256,
    totalSupplySlot: UInt256,
    vaultTotalAssetsSlot: UInt256,
    baseAssets: UFix64,
    priceMultiplier: UFix64,
    signer: Test.TestAccount
) {
    let result = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_erc4626_vault_price.cdc"),
            authorizers: [signer.address],
            signers: [signer],
            arguments: [vaultAddress, assetAddress, assetBalanceSlot, totalSupplySlot, vaultTotalAssetsSlot, baseAssets, priceMultiplier]
        )
    )
    Test.expect(result, Test.beSucceeded())
}

/* --- Uniswap V3 Pool State Manipulation --- */

/// Set Uniswap V3 pool to a specific price via EVM.store
/// Creates pool if it doesn't exist, then manipulates state
access(all) fun setPoolToPrice(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix64,
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
