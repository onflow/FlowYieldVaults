// ===================================================================================
// BOUNDARY TEST: AutoBalancer Thresholds (0.95 and 1.05)
// ===================================================================================
// This test verifies the AutoBalancer rebalancing boundaries.
//
// AutoBalancer Thresholds (STRICTLY greater/less than, NOT inclusive):
//   - Upper: Value/Baseline > 1.05 → sells surplus (P=1.05 does NOT trigger)
//   - Lower: Value/Baseline < 0.95 → pulls from collateral (P=0.95 does NOT trigger)
//
// At initial state (U=615.38, B=615.38, P=1.0):
//   Value/Baseline = (U × P) / B = P
//
// NOTE: setVaultSharePrice uses ABSOLUTE pricing (not cumulative)
//
// ===================================================================================
// TEST OUTPUT (actual values from test run)
// ===================================================================================
//
// UPPER BOUNDARY TEST (1.05 threshold)
// Initial balance: 999.83077766
// Initial state: U=615.38, B=615.38, P=1.0
//
// Price: 1.04
//   State: C=1000.00, D=615.38, U=615.38, H=1.30, B=615.38
//   Value/Baseline ratio: 1.04
//   Balance before: 999.83, after: 999.83, Change: +0.00
//   Expected: NO rebalance (ratio < 1.05) ✓
//
// Price: 1.05
//   State: C=1000.00, D=615.38, U=615.38, H=1.30, B=615.38
//   Value/Baseline ratio: 1.05
//   Balance before: 999.83, after: 999.83, Change: +0.00
//   Expected: AT BOUNDARY - NO rebalance (>= does NOT trigger, only > triggers) ✓
//
// Price: 1.06
//   State: C=1036.92, D=638.10, U=603.27, H=1.30, B=639.47
//   Value/Baseline ratio: 1.06
//   Balance before: 999.83, after: 988.85, Change: -10.98
//   Expected: REBALANCE (ratio > 1.05) ✓
//   → Surplus sold, collateral increased, debt increased, units decreased
//
// ===================================================================================
//
// LOWER BOUNDARY TEST (0.95 threshold)
// Initial balance: 999.83077766
// Initial state: U=615.38, B=615.38, P=1.0
//
// Price: 0.96
//   State: C=1000.00, D=615.38, U=615.38, H=1.30, B=615.38
//   Value/Baseline ratio: 0.96
//   Balance before: 999.83, after: 999.83, Change: +0.00
//   Expected: NO rebalance (ratio > 0.95) ✓
//
// Price: 0.95
//   State: C=1000.00, D=615.38, U=615.38, H=1.30, B=615.38
//   Value/Baseline ratio: 0.95
//   Balance before: 999.83, after: 999.83, Change: +0.00
//   Expected: AT BOUNDARY - NO rebalance (<= does NOT trigger, only < triggers) ✓
//
// Price: 0.94
//   State: C=1000.00, D=615.38, U=615.38, H=1.30, B=615.38
//   Value/Baseline ratio: 0.94
//   Balance before: 999.83, after: 999.83, Change: +0.00
//   Expected: REBALANCE (ratio < 0.95) ✗ DID NOT TRIGGER!
//   → Deficit rebalance blocked because Position health already at target (1.3)
//   → maxWithdraw() returns 0 when preHealth <= targetHealth
//   → See FlowALPv0.cdc:1412-1414 and FlowYieldVaultsStrategiesV2.cdc:439
//
// ===================================================================================
// KEY FINDINGS:
// ===================================================================================
// 1. Upper boundary (surplus): Works correctly
//    - Threshold is STRICTLY > 1.05 (not >=)
//    - At P=1.06: C increases, D increases, U decreases (surplus sold, re-leveraged)
//
// 2. Lower boundary (deficit): DOES NOT TRIGGER
//    - Threshold is STRICTLY < 0.95 (not <=)
//    - Even at P=0.94 (below threshold), no rebalance occurs
//    - Reason: Position health is already at target (H=1.3)
//    - PositionSource with pullFromTopUpSource:false returns 0 available
//    - AutoBalancer cannot pull collateral to buy yield tokens
//
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
import "DeFiActions"

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

    // Expected values after rebalance for each price point
    // Format: {price: [C, D, U, H]}
    // - For prices < 1.05: No rebalance, values stay at initial
    // - For prices > 1.05: Rebalance triggers, surplus sold and re-leveraged
    let initialC = 1000.0
    let initialD = 615.38461538
    let initialU = 615.38461537
    let initialH = 1.3

    // Expected values per price (from actual test runs)
    let expectedValues: {UFix64: [UFix64; 4]} = {
        // P=1.04: No rebalance (< 1.05 threshold)
        1.04: [initialC, initialD, initialU, initialH],
        // P=1.05: No rebalance (at boundary, threshold is strictly >)
        1.05: [initialC, initialD, initialU, initialH],
        // P=1.06: Rebalance triggers (> 1.05 threshold)
        // Surplus sold, collateral increased, debt increased, units decreased
        1.06: [1036.91569107, 638.10196373, 603.26887228, initialH]
    }

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

        // Track events before rebalance
        let yieldVaultEventsBefore = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let positionEventsBefore = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length

        // Rebalance with force=false to test threshold behavior
        rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

        // Track events after rebalance
        let yieldVaultEventsAfter = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let positionEventsAfter = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length
        let newYieldVaultEvents = yieldVaultEventsAfter - yieldVaultEventsBefore
        let newPositionEvents = positionEventsAfter - positionEventsBefore

        // Log state after rebalance: C, D, U, H, B
        let positionCollateral = getFlowCollateralFromPosition(pid: pid)
        let positionDebt = getMOETDebtFromPosition(pid: pid)
        let positionHealth = getPositionHealth(pid: pid, beFailed: false)
        let yieldTokenUnits = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
        let baseline = getAutoBalancerBaseline(id: yieldVaultIDs![0]) ?? 0.0

        let balanceAfterRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        // Calculate Value/Baseline ratio
        let ratio = price  // At initial state, Value/Baseline = Price

        log("---")
        log("Price: \(price)")
        log("  State: C=\(positionCollateral), D=\(positionDebt), U=\(yieldTokenUnits), H=\(positionHealth), B=\(baseline)")
        log("  Value/Baseline ratio: \(ratio)")
        log("  Balance before rebalance: \(balanceBeforeRebalance)")
        log("  Balance after rebalance:  \(balanceAfterRebalance)")
        if balanceAfterRebalance >= balanceBeforeRebalance {
            log("  Change: +\(balanceAfterRebalance - balanceBeforeRebalance)")
        } else {
            log("  Change: -\(balanceBeforeRebalance - balanceAfterRebalance)")
        }
        log("  New YieldVault rebalance events: \(newYieldVaultEvents), New Position rebalance events: \(newPositionEvents)")

        if ratio < 1.05 {
            log("  Expected: NO rebalance (ratio < 1.05)")
        } else if ratio == 1.05 {
            log("  Expected: AT BOUNDARY (check if >= or > triggers)")
        } else {
            log("  Expected: REBALANCE (ratio > 1.05)")
        }

        // Assert expected values
        let expected = expectedValues[price]!
        let tolerance = 0.00000001
        Test.assert(
            positionCollateral >= expected[0] - tolerance && positionCollateral <= expected[0] + tolerance,
            message: "P=\(price): Expected C=\(expected[0]), got \(positionCollateral)"
        )
        Test.assert(
            positionDebt >= expected[1] - tolerance && positionDebt <= expected[1] + tolerance,
            message: "P=\(price): Expected D=\(expected[1]), got \(positionDebt)"
        )
        Test.assert(
            yieldTokenUnits >= expected[2] - tolerance && yieldTokenUnits <= expected[2] + tolerance,
            message: "P=\(price): Expected U=\(expected[2]), got \(yieldTokenUnits)"
        )
        // Health factor has more decimal places, use larger tolerance
        let healthTolerance = 0.0001
        Test.assert(
            positionHealth >= UFix128(expected[3]) - UFix128(healthTolerance) && positionHealth <= UFix128(expected[3]) + UFix128(healthTolerance),
            message: "P=\(price): Expected H=\(expected[3]), got \(positionHealth)"
        )

        // Assert rebalance events
        if ratio > 1.05 {
            Test.assert(newYieldVaultEvents == 1, message: "P=\(price): Expected 1 YieldVault rebalance event, got \(newYieldVaultEvents)")
            Test.assert(newPositionEvents == 1, message: "P=\(price): Expected 1 Position rebalance event, got \(newPositionEvents)")
        } else {
            Test.assert(newYieldVaultEvents == 0, message: "P=\(price): Expected 0 YieldVault rebalance events, got \(newYieldVaultEvents)")
            Test.assert(newPositionEvents == 0, message: "P=\(price): Expected 0 Position rebalance events, got \(newPositionEvents)")
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
    let testPrices: [UFix64] = [0.96, 0.95, 0.94, 0.1]

    // Expected values after rebalance for each price point
    // Format: {price: [C, D, U, H]}
    // NOTE: Due to pullFromTopUpSource:false and Position health at target (1.3),
    // deficit rebalancing NEVER triggers - maxWithdraw() returns 0
    // See: FlowALPv0.cdc:1411-1414, FlowYieldVaultsStrategiesV2.cdc:439
    let initialC = 1000.0
    let initialD = 615.38461538
    let initialU = 615.38461537
    let initialH = 1.3

    // All prices: No rebalance triggers (deficit rebalancing is blocked)
    let expectedValues: {UFix64: [UFix64; 4]} = {
        0.96: [initialC, initialD, initialU, initialH],  // Above threshold, no rebalance expected
        0.95: [initialC, initialD, initialU, initialH],  // At boundary, no rebalance (threshold is strictly <)
        0.94: [initialC, initialD, initialU, initialH],  // Below threshold, but BLOCKED by maxWithdraw()=0
        0.1:  [initialC, initialD, initialU, initialH]   // Far below threshold, still BLOCKED
    }

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

        let yieldVaultEventsBefore = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let positionEventsBefore = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length

        rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

        let yieldVaultEventsAfter = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let positionEventsAfter = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length
        let newYieldVaultEvents = yieldVaultEventsAfter - yieldVaultEventsBefore
        let newPositionEvents = positionEventsAfter - positionEventsBefore

        // Log state after rebalance: C, D, U, H, B
        let positionCollateral = getFlowCollateralFromPosition(pid: pid)
        let positionDebt = getMOETDebtFromPosition(pid: pid)
        let positionHealth = getPositionHealth(pid: pid, beFailed: false)
        let yieldTokenUnits = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
        let baseline = getAutoBalancerBaseline(id: yieldVaultIDs![0]) ?? 0.0

        let balanceAfterRebalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!

        let ratio = price

        log("---")
        log("Price: \(price)")
        log("  New YieldVault rebalance events: \(newYieldVaultEvents), New Position rebalance events: \(newPositionEvents)")
        if newYieldVaultEvents > 0 {
            let lastEvent = Test.eventsOfType(Type<DeFiActions.Rebalanced>())[yieldVaultEventsAfter - 1] as! DeFiActions.Rebalanced
            log("  DeFiActions.Rebalanced - amount: \(lastEvent.amount), value: \(lastEvent.value), isSurplus: \(lastEvent.isSurplus)")
        }
        if newPositionEvents > 0 {
            let lastPosEvent = Test.eventsOfType(Type<FlowALPv0.Rebalanced>())[positionEventsAfter - 1] as! FlowALPv0.Rebalanced
            log("  FlowALPv0.Rebalanced - atHealth: \(lastPosEvent.atHealth), amount: \(lastPosEvent.amount), fromUnder: \(lastPosEvent.fromUnder)")
        }
        log("  State: C=\(positionCollateral), D=\(positionDebt), U=\(yieldTokenUnits), H=\(positionHealth), B=\(baseline)")
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
            log("  Expected: REBALANCE (ratio < 0.95) - BUT BLOCKED by maxWithdraw()=0")
        }

        // Assert expected values
        let expected = expectedValues[price]!
        let tolerance = 0.00000001
        Test.assert(
            positionCollateral >= expected[0] - tolerance && positionCollateral <= expected[0] + tolerance,
            message: "P=\(price): Expected C=\(expected[0]), got \(positionCollateral)"
        )
        Test.assert(
            positionDebt >= expected[1] - tolerance && positionDebt <= expected[1] + tolerance,
            message: "P=\(price): Expected D=\(expected[1]), got \(positionDebt)"
        )
        Test.assert(
            yieldTokenUnits >= expected[2] - tolerance && yieldTokenUnits <= expected[2] + tolerance,
            message: "P=\(price): Expected U=\(expected[2]), got \(yieldTokenUnits)"
        )
        // Health factor has more decimal places, use larger tolerance
        let healthTolerance = 0.0001
        Test.assert(
            positionHealth >= UFix128(expected[3]) - UFix128(healthTolerance) && positionHealth <= UFix128(expected[3]) + UFix128(healthTolerance),
            message: "P=\(price): Expected H=\(expected[3]), got \(positionHealth)"
        )

        // Assert NO rebalance events (deficit rebalancing is blocked)
        // Even when ratio < 0.95, no events are emitted because maxWithdraw() returns 0
        Test.assert(newYieldVaultEvents == 0, message: "P=\(price): Expected 0 YieldVault rebalance events (blocked), got \(newYieldVaultEvents)")
        Test.assert(newPositionEvents == 0, message: "P=\(price): Expected 0 Position rebalance events (blocked), got \(newPositionEvents)")
    }

    log("=============================================================================")
}
