/// TracerStrategy Test Suite
///
/// Tests the bidirectional capital flow between Position (FlowALP) and AutoBalancer
/// in response to yield token price changes.
///
/// ## Architecture Overview
///
/// ```
/// User Deposit (FLOW)
///   ↓
/// YieldVault (TracerStrategy)
///   ├─ Position (FlowALP)
///   │    ├─ Collateral: FLOW
///   │    ├─ Debt: MOET
///   │    ├─ Health: collateral_value / debt
///   │    ├─ Target Health: 1.3
///   │    └─ Min Health: 1.1 (liquidation at 1.0)
///   │
///   └─ AutoBalancer
///        ├─ Holdings: YieldToken (YT)
///        ├─ Tracks: deposit value vs current value
///        ├─ Thresholds: 0.95 (pull) / 1.05 (push)
///        └─ Rebalances: via positionSwapSource/Sink
/// ```
///
/// ## Capital Flow Mechanisms
///
/// ### 1. Position → AutoBalancer (DrawDownSink: abaSwapSink)
/// - When: Position health > target (overcollateralized)
/// - How: Position borrows more MOET → swaps to YT → deposits to AutoBalancer
/// - Purpose: Maintain target health, increase YT holdings
///
/// ### 2. AutoBalancer → Position (RebalanceSink: positionSwapSink)
/// - When: AutoBalancer value > deposits (surplus)
/// - How: Swaps YT → FLOW → deposits to Position
/// - Purpose: Recollateralize Position, lock in gains
///
/// ### 3. Position ← AutoBalancer (RebalanceSource: positionSwapSource)
/// - When: AutoBalancer value < deposits (deficit)
/// - How: Pulls FLOW from Position → swaps to YT → refills AutoBalancer
/// - Purpose: Recover from YT price drops
/// - Limit: Position maintains health ≥ minHealth (aggressive) or target (conservative)
///
/// ## Key Behaviors
///
/// ### YT Price Increases (test_RebalanceYieldVaultSucceeds)
/// 1. YT price ↑ → AutoBalancer value > deposits
/// 2. AutoBalancer pushes surplus to Position (via rebalanceSink)
/// 3. Position health > target
/// 4. Position borrows more MOET, pushes to AutoBalancer (via drawDownSink)
/// 5. Result: Increased leverage, more YT exposure
///
/// ### YT Price Decreases (test_RebalanceYieldVaultSucceedsAfterYieldPriceDecrease)
/// 1. YT price ↓ → AutoBalancer value < deposits
/// 2. AutoBalancer pulls FLOW from Position (via rebalanceSource)
/// 3. Swaps FLOW → YT to partially recover
/// 4. Position health drops (FLOW collateral reduced)
/// 5. Position pulls from topUpSource to restore health
/// 6. Result: Partial recovery, but still significant loss
///
/// ### Position Health Independence
/// - Position health = FLOW_value / MOET_debt
/// - Position holds FLOW (not YT), so YT price changes don't directly affect Position health
/// - Position health only changes when AutoBalancer pulls/pushes collateral
/// - This is why position rebalancing appears as "no-op" after YT price changes alone
///
import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "MockStrategies"
import "FlowALPv0"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@MockStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let targetHealthFactor = 1.3

// starting token prices
access(all) let startingFlowPrice = 1.0
access(all) let startingYieldPrice = 1.0

// used to reset test state - should be assigned at the end of setup()
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	deployContracts()

    // set mocked token prices
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: startingYieldPrice)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: startingFlowPrice)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // setup FlowALP with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: flowCollateralFactor,
        borrowFactor: flowBorrowFactor,
        yearlyRate: UFix128(0.0),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves
	let openRes = executeTransaction(
		"../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: flowYieldVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@MockStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: MockStrategies.IssuerStoragePath,
		beFailed: false
	)

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
	mintFlow(to: flowYieldVaultsAccount, amount: 100.0)

	snapshot = getCurrentBlockHeight()
}

access(all)
fun test_SetupSucceeds() {
	log("Success: TracerStrategy setup succeeded")
}

access(all)
fun test_CreateYieldVaultSucceeds() {
	let fundingAmount = 100.0

	let user = Test.createAccount()
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	let yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)
}

access(all)
fun test_CloseYieldVaultSucceeds() {
	Test.reset(to: snapshot)

	let fundingAmount = 100.0

	let user = Test.createAccount()
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(0, yieldVaultIDs!.length)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

	Test.assertEqual(fundingAmount, flowBalanceAfter)
}

access(all)
fun test_RebalanceYieldVaultSucceeds() {
	Test.reset(to: snapshot)

    let fundingAmount = 100.0
    let yieldTokenPriceIncrease = 0.2

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    createYieldVault(signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)
    let yieldVaultID = yieldVaultIDs![0]

    let autoBalancerValueBefore = getAutoBalancerCurrentValue(id: yieldVaultID)!
    let yieldVaultBalanceBeforePriceIncrease = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultID)

    setMockOraclePrice(signer: flowYieldVaultsAccount,
        forTokenIdentifier: yieldTokenIdentifier,
        price: startingYieldPrice * (1.0 + yieldTokenPriceIncrease)
    )

    let autoBalancerValueAfter = getAutoBalancerCurrentValue(id: yieldVaultID)!
    let yieldVaultBalanceAfterPriceIncrease = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultID)

    // Rebalance YieldVault: AutoBalancer detects surplus (YT value increased from $61.54 to $73.85)
    // and pushes excess value to Position via rebalanceSink (positionSwapSink: YT -> FLOW swap -> Position)
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultID, force: true, beFailed: false)

    // Verify AutoBalancer pushed surplus to Position by checking Deposited event
    let autoBalancerRecollateralizeEvent = getLastPositionDepositedEvent(Test.eventsOfType(Type<FlowALPv0.Deposited>())) as! FlowALPv0.Deposited
    Test.assertEqual(positionID, autoBalancerRecollateralizeEvent.pid)
    Test.assertEqual(autoBalancerRecollateralizeEvent.amount,
        (autoBalancerValueAfter - autoBalancerValueBefore) / startingFlowPrice
    )

    // Position rebalance: Position health increased above target (1.3) due to AutoBalancer depositing
    // extra collateral. Position rebalances by borrowing more MOET and pushing to drawDownSink
    // (abaSwapSink: MOET -> YT -> AutoBalancer) to bring health back to target.
    rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let positionFlowBalance = findBalance(details: positionDetails, vaultType: Type<@FlowToken.Vault>()) ?? 0.0

    // The math here is a little off, expected amount is around 130, but the final value of the yield vault is 127
    let initialLoan = fundingAmount * (flowCollateralFactor / targetHealthFactor)
    let expectedBalance = initialLoan * yieldTokenPriceIncrease + fundingAmount
    log("Position Flow balance after rebalance: \(positionFlowBalance)")
    Test.assert(positionFlowBalance > fundingAmount,
        message: "Expected user's Flow balance in their position after rebalance to be more than \(fundingAmount) but got \(positionFlowBalance)"
    )

    let positionAvailBal = positionAvailableBalance(
            pid: positionID,
            type: flowTokenIdentifier,
            pullFromSource: true,
            beFailed: false
        )
    log("Pool.availableBalance(pid: \(positionID), type: $FLOW, pullFromSource: true) == \(positionAvailBal)")

    // TODO - position balance causing error here - need to fix position balance calculation
    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(0, yieldVaultIDs!.length)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter-flowBalanceBefore) >= expectedBalance,
        message: "Expected user's Flow balance after rebalance to be at least \(expectedBalance) but got \(flowBalanceAfter)"
    )
}

access(all)
fun test_RebalanceYieldVaultSucceedsAfterYieldPriceDecrease() {
    Test.reset(to: snapshot)

	let fundingAmount = 100.0
	let priceDecrease = 0.1

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)

	var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("YieldVault balance before yield increase: \(yieldVaultBalance ?? 0.0)")

	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: priceDecrease)

	yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("YieldVault balance before rebalance: \(yieldVaultBalance ?? 0.0)")

	// Rebalance YieldVault: AutoBalancer detects deficit (YT value dropped from $61.54 to $6.15)
	// and pulls FLOW from Position via rebalanceSource, swaps to YT to partially recover
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	// Position rebalance: Position health dropped below target after AutoBalancer pulled collateral,
	// so it pulls from topUpSource to restore health. Position holds FLOW (not YT), so its health
	// is not directly affected by YT price changes - only by AutoBalancer pulling collateral.
	rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(0, yieldVaultIDs!.length)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	// After rebalancing, actual loss is ~30-35% (user gets back ~65-70 FLOW from 100 FLOW deposit)
	//
	// Loss breakdown:
	// 1. YT price drops 90% ($1.00 -> $0.10), AutoBalancer holds ~61.54 YT
	// 2. AutoBalancer value drops from $61.54 to $6.15 (loses $55.39)
	// 3. AutoBalancer pulls ~24 FLOW from Position via rebalanceSource, swaps to YT
	// 4. Position health drops from 1.3 to ~1.1, triggers topUpSource pull to restore health
	// 5. User ends up with ~65-70 FLOW (30-35% loss)
	//
	// This is significantly better than without rebalanceSource (would be ~94% loss)
	// but still substantial due to the extreme 90% price crash.
	let returned = flowBalanceAfter - flowBalanceBefore
	Test.assert(equalAmounts(a: returned, b: fundingAmount * 0.65, tolerance: 1.0),
		message: "Expected ~65-70 FLOW returned after 90% YT crash (got \(returned))")
}

access(all)
fun test_RebalanceYieldVaultSucceedsAfterCollateralPriceIncrease() {
    Test.reset(to: snapshot)

    let fundingAmount = 100.0
    let collateralPriceIncrease = 5.0

    let user = Test.createAccount()

    // Likely 0.0
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    // Set a high collateral price to simulate a scenario where the collateral value increases significantly
    // This should cause the rebalance to increase the amount of Yield tokens held in the YieldVault
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: collateralPriceIncrease)

    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!

    log("Yield token balance before rebalance: \(yieldTokensBefore)")

    // Position health increased because FLOW collateral is worth more; drawDown brings it back to target.
    // Position ID is hardcoded to 1 here since this is the first yield vault created,
    // if there is a better way to get the position ID, please let me know
    rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

    let yieldTokensAfter = getAutoBalancerBalance(id: yieldVaultIDs![0])!

    log("Yield token balance after rebalance: \(yieldTokensAfter)")

    // the ratio of yield tokens after the rebalance should be directly proportional to the collateral price increase, 
    // as we started with 1.0 for all values.
    Test.assert(yieldTokensAfter >= (yieldTokensBefore * collateralPriceIncrease) - TOLERANCE,
        message: "Expected user's Flow balance after rebalance to be more than funding amount but got \(yieldTokensAfter)"
    )

    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

    yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(0, yieldVaultIDs!.length)
}
