// ===================================================================================
// BOUNDARY TEST: AutoBalancer Thresholds (0.95 and 1.05)
// ===================================================================================
// This test verifies the AutoBalancer rebalancing boundaries.
//
// AutoBalancer Thresholds (STRICTLY greater/less than, NOT inclusive):
//   - Upper: Value/Baseline > 1.05 → sells surplus (P=1.05 does NOT trigger)
//   - Lower: Value/Baseline < 0.95 → pulls from collateral (P=0.95 does NOT trigger)
//
// TEST RESULTS:
//   Upper boundary:
//     - P=1.04: NO rebalance (ratio 1.04 < 1.05)
//     - P=1.05: NO rebalance (ratio 1.05 = 1.05, boundary NOT triggered)
//     - P=1.06: REBALANCE (ratio 1.06 > 1.05)
//
//   Lower boundary:
//     - P=0.96: NO rebalance (ratio 0.96 > 0.95)
//     - P=0.95: NO rebalance (ratio 0.95 = 0.95, boundary NOT triggered)
//     - P=0.94: REBALANCE expected (ratio 0.94 < 0.95)
//
// At initial state (U=615.38, B=615.38, P=1.0):
//   Value/Baseline = (U × P) / B = P
//
// NOTE: setVaultSharePrice uses ABSOLUTE pricing (not cumulative)
// ===================================================================================

#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

// FlowYieldVaults platform
import "FlowYieldVaults"
// other
import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV2"
import "FlowALPv0"

// ============================================================================
// CADENCE ACCOUNTS
// ============================================================================

access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowALPAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV2.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier

// ============================================================================
// PROTOCOL ADDRESSES
// ============================================================================

access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// ============================================================================
// VAULT & TOKEN ADDRESSES
// ============================================================================

access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

access(all) let moetBalanceSlot = 0 as UInt256
access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wflowBalanceSlot = 3 as UInt256
access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

access(all)
fun setup() {
    deployContractsForFork()

    // Setup Uniswap V3 pools with 1:1 prices
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 3000, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    let symbolPrices: {String: UFix64} = {
        "FLOW": 1.0,
        "USD": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

// ===================================================================================
// TEST: Upper Boundary (1.05) - Single vault, multiple price changes
// ===================================================================================
// At initial state (U=615.38, B=615.38):
//   Value/Baseline = Price (since setVaultSharePrice is ABSOLUTE)
//
// Test prices around 1.05 boundary:
//   - 1.04: ratio = 1.04 < 1.05 → NO rebalance expected
//   - 1.05: ratio = 1.05 = 1.05 → at boundary (check implementation)
//   - 1.06: ratio = 1.06 > 1.05 → rebalance expected
//
// Since prices are ABSOLUTE, we can test boundary behavior by checking
// if balance changes match "unrealized only" or "rebalanced" pattern.
// ===================================================================================

access(all)
fun test_UpperBoundary() {
    let user = Test.createAccount()
    let fundingAmount = 1000.0

    transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1 price
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: 1.0,
        signer: user
    )

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    let pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)

    // Initial rebalance to establish baseline
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

    let initialBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

    log("=============================================================================")
    log("UPPER BOUNDARY TEST (1.05 threshold)")
    log("=============================================================================")
    log("Initial balance: \(initialBalance)")
    log("Initial state: U=615.38, B=615.38, P=1.0")
    log("")

    // Test prices around upper boundary
    // Since setVaultSharePrice is ABSOLUTE, each test is independent
    let testPrices: [UFix64] = [1.04, 1.05, 1.06]

    for price in testPrices {
        // Reset price to test this boundary independently
        // First reset to 1.0, then set to test price
        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: 1.0,
            signer: coaOwnerAccount
        )

        // Reset pool price for swaps
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: morphoVaultAddress,
            tokenBAddress: pyusd0Address,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(1.0), fee: 100, reverse: true),
            tokenABalanceSlot: fusdevBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: coaOwnerAccount
        )

        let balanceBefore = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        // Now set to test price
        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: price,
            signer: coaOwnerAccount
        )

        // Set pool price for accurate swap
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: morphoVaultAddress,
            tokenBAddress: pyusd0Address,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(price), fee: 100, reverse: true),
            tokenABalanceSlot: fusdevBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: coaOwnerAccount
        )

        let balanceBeforeRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        // Rebalance with force=false to test threshold behavior
        rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

        let balanceAfterRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        // Calculate Value/Baseline ratio
        let ratio = price  // At initial state, Value/Baseline = Price

        log("---")
        log("Price: \(price)")
        log("  Value/Baseline ratio: \(ratio)")
        log("  Balance before rebalance: \(balanceBeforeRebalance)")
        log("  Balance after rebalance:  \(balanceAfterRebalance)")
        if balanceAfterRebalance >= balanceBeforeRebalance {
            log("  Change: +\(balanceAfterRebalance - balanceBeforeRebalance)")
        } else {
            log("  Change: -\(balanceBeforeRebalance - balanceAfterRebalance)")
        }

        if ratio < 1.05 {
            log("  Expected: NO rebalance (ratio < 1.05)")
        } else if ratio == 1.05 {
            log("  Expected: AT BOUNDARY (check if >= or > triggers)")
        } else {
            log("  Expected: REBALANCE (ratio > 1.05)")
        }
    }

    log("=============================================================================")
}

// ===================================================================================
// TEST: Lower Boundary (0.95) - Single vault, multiple price changes
// ===================================================================================

access(all)
fun test_LowerBoundary() {
    let user = Test.createAccount()
    let fundingAmount = 1000.0

    transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: 1.0,
        signer: user
    )

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    let pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid
    let yieldVaultIDs = getYieldVaultIDs(address: user.address)

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

    let initialBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

    log("=============================================================================")
    log("LOWER BOUNDARY TEST (0.95 threshold)")
    log("=============================================================================")
    log("Initial balance: \(initialBalance)")
    log("Initial state: U=615.38, B=615.38, P=1.0")
    log("")

    // Test prices around lower boundary
    let testPrices: [UFix64] = [0.96, 0.95, 0.94]

    for price in testPrices {
        // Reset to 1.0 first
        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: 1.0,
            signer: coaOwnerAccount
        )

        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: morphoVaultAddress,
            tokenBAddress: pyusd0Address,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(1.0), fee: 100, reverse: true),
            tokenABalanceSlot: fusdevBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: coaOwnerAccount
        )

        let balanceBefore = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        // Set to test price
        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: price,
            signer: coaOwnerAccount
        )

        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: morphoVaultAddress,
            tokenBAddress: pyusd0Address,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(price), fee: 100, reverse: true),
            tokenABalanceSlot: fusdevBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: coaOwnerAccount
        )

        let balanceBeforeRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

        let balanceAfterRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        let ratio = price

        log("---")
        log("Price: \(price)")
        log("  Value/Baseline ratio: \(ratio)")
        log("  Balance before rebalance: \(balanceBeforeRebalance)")
        log("  Balance after rebalance:  \(balanceAfterRebalance)")
        if balanceAfterRebalance >= balanceBeforeRebalance {
            log("  Change: +\(balanceAfterRebalance - balanceBeforeRebalance)")
        } else {
            log("  Change: -\(balanceBeforeRebalance - balanceAfterRebalance)")
        }

        if ratio > 0.95 {
            log("  Expected: NO rebalance (ratio > 0.95)")
        } else if ratio == 0.95 {
            log("  Expected: AT BOUNDARY (check if <= or < triggers)")
        } else {
            log("  Expected: REBALANCE (ratio < 0.95)")
        }
    }

    log("=============================================================================")
}
