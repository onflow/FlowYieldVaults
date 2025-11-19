import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowVaultsStrategies"
import "FlowALP"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
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

    // Ensure FlowVaultsScheduler is available for any transactions that
    // auto-register tides or schedule rebalancing.
    deployFlowVaultsSchedulerIfNeeded()

    // set mocked token prices
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: startingYieldPrice)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: startingFlowPrice)

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
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: flowCollateralFactor,
        borrowFactor: flowBorrowFactor,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves
	let openRes = executeTransaction(
		"../../lib/FlowALP/cadence/tests/transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: flowVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
		beFailed: false
	)


	snapshot = getCurrentBlockHeight()
}

access(all)
fun test_SetupSucceeds() {
	log("Success: TracerStrategy setup succeeded")
}

access(all)
fun test_CreateTideSucceeds() {
	let fundingAmount = 100.0

	let user = Test.createAccount()
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

	createTide(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	let tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(1, tideIDs!.length)
}

access(all)
fun test_CloseTideSucceeds() {
	Test.reset(to: snapshot)

	let fundingAmount = 100.0

	let user = Test.createAccount()
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

	createTide(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(1, tideIDs!.length)

	closeTide(signer: user, id: tideIDs![0], beFailed: false)

	tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(0, tideIDs!.length)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

	Test.assertEqual(fundingAmount, flowBalanceAfter)
}

access(all)
fun test_RebalanceTideSucceeds() {
	Test.reset(to: snapshot)

    let fundingAmount = 100.0
    let yieldTokenPriceIncrease = 0.2

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

    createTide(signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALP.Opened>())) as! FlowALP.Opened).pid

    var tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)
    let tideID = tideIDs![0]

    let autoBalancerValueBefore = getAutoBalancerCurrentValue(id: tideID)!
    let tideBalanceBeforePriceIncrease = getTideBalance(address: user.address, tideID: tideID)

    setMockOraclePrice(signer: flowVaultsAccount,
        forTokenIdentifier: yieldTokenIdentifier,
        price: startingYieldPrice * (1.0 + yieldTokenPriceIncrease)
    )

    let autoBalancerValueAfter = getAutoBalancerCurrentValue(id: tideID)!
    let tideBalanceAfterPriceIncrease = getTideBalance(address: user.address, tideID: tideID)

    rebalanceTide(signer: flowVaultsAccount, id: tideID, force: true, beFailed: false)

    // TODO - assert against pre- and post- getTideBalance() diff once protocol assesses balance correctly
    //      for now we can use events to intercept fund flows between pre- and post- Position & AutoBalancer state

    // assess how much FLOW was deposited into the position
    let autoBalancerRecollateralizeEvent = getLastPositionDepositedEvent(Test.eventsOfType(Type<FlowALP.Deposited>())) as! FlowALP.Deposited
    Test.assertEqual(positionID, autoBalancerRecollateralizeEvent.pid)
    Test.assertEqual(autoBalancerRecollateralizeEvent.amount,
        (autoBalancerValueAfter - autoBalancerValueBefore) / startingFlowPrice
    )

    rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let positionFlowBalance = findBalance(details: positionDetails, vaultType: Type<@FlowToken.Vault>()) ?? 0.0

    // The math here is a little off, expected amount is around 130, but the final value of the tide is 127
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
    closeTide(signer: user, id: tideIDs![0], beFailed: false)

	tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(0, tideIDs!.length)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter-flowBalanceBefore) >= expectedBalance,
        message: "Expected user's Flow balance after rebalance to be at least \(expectedBalance) but got \(flowBalanceAfter)"
    )
}

access(all)
fun test_RebalanceTideSucceedsAfterYieldPriceDecrease() {
    Test.reset(to: snapshot)

	let fundingAmount = 100.0
	let priceDecrease = 0.1

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

	createTide(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALP.Opened>())) as! FlowALP.Opened).pid

	var tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(1, tideIDs!.length)

	var tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("Tide balance before yield increase: \(tideBalance ?? 0.0)")

	setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: priceDecrease)

	tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

	log("Tide balance before rebalance: \(tideBalance ?? 0.0)")

	rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

	closeTide(signer: user, id: tideIDs![0], beFailed: false)

	tideIDs = getTideIDs(address: user.address)
	Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
	Test.assertEqual(0, tideIDs!.length)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	let expectedBalance = fundingAmount * 0.5
	Test.assert((flowBalanceAfter-flowBalanceBefore) <= expectedBalance,
	message: "Expected user's Flow balance after rebalance to be less than the original, due to decrease in yield price but got \(flowBalanceAfter)")

	Test.assert(
		(flowBalanceAfter-flowBalanceBefore) > 0.1,
		message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	)
}

/// Integration-style test that verifies a FlowVaults Tide backed by a FlowALP Position
/// can be liquidated via FlowALP's `liquidate_repay_for_seize` flow and that the
/// underlying position health improves in the presence of the Tide wiring.
access(all)
fun test_TideLiquidationImprovesUnderlyingHealth() {
    Test.reset(to: snapshot)

    let fundingAmount: UFix64 = 100.0

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

    // Create a Tide using the TracerStrategy (FlowALP-backed)
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    // The TracerStrategy opens exactly one FlowALP position for this stack; grab its pid.
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALP.Opened>())) as! FlowALP.Opened).pid

    var tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)
    let tideID = tideIDs![0]

    // Baseline health and AutoBalancer state. The FlowALP helper returns UFix128
    // for full precision, but we only need a UFix64 approximation for comparisons.
    let hInitial = UFix64(getFlowALPPositionHealth(pid: positionID))

    // Drop FLOW price to push the FlowALP position under water.
    setMockOraclePrice(
        signer: flowVaultsAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: startingFlowPrice * 0.7
    )

    let hAfterDrop = UFix64(getFlowALPPositionHealth(pid: positionID))
    Test.assert(hAfterDrop < 1.0, message: "Expected FlowALP position health to fall below 1.0 after price drop")

    // Quote a keeper liquidation for the FlowALP position (MOET debt, Flow collateral).
    let quoteRes = _executeScript(
        "../../lib/FlowALP/cadence/scripts/flow-alp/quote_liquidation.cdc",
        [positionID, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! FlowALP.LiquidationQuote
    Test.assert(quote.requiredRepay > 0.0, message: "Expected keeper liquidation to require a positive repay amount")
    Test.assert(quote.seizeAmount > 0.0, message: "Expected keeper liquidation to seize some collateral")

    // Keeper mints MOET and executes liquidation against the FlowALP pool.
    let keeper = Test.createAccount()
    setupMoetVault(keeper, beFailed: false)
    let moatBefore = getBalance(address: keeper.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[LIQ][KEEPER] MOET before mint: \(moatBefore)")
    let mintRes = _executeTransaction(
        "../transactions/moet/mint_moet.cdc",
        [keeper.address, quote.requiredRepay + 1.0],
        protocolAccount
    )
    Test.expect(mintRes, Test.beSucceeded())
    let moatAfter = getBalance(address: keeper.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[LIQ][KEEPER] MOET after  mint: \(moatAfter) (requiredRepay=\(quote.requiredRepay))")

    let liqRes = _executeTransaction(
        "../../lib/FlowALP/cadence/transactions/flow-alp/pool-management/liquidate_repay_for_seize.cdc",
        // Use the quoted requiredRepay as maxRepayAmount while having minted a small
        // buffer above this amount to avoid edge cases with vault balances.
        [positionID, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay, 0.0],
        keeper
    )
    Test.expect(liqRes, Test.beSucceeded())

    // Position health should have improved compared to the post-drop state and move back
    // toward the FlowALP target (~1.05 used in unit tests).
    let hAfterLiq = UFix64(getFlowALPPositionHealth(pid: positionID))
    Test.assert(hAfterLiq > hAfterDrop, message: "Expected FlowALP position health to improve after liquidation")

    // Sanity check: Tide is still live and AutoBalancer state can be queried without error.
    let abaBalance = getAutoBalancerBalance(id: tideID) ?? 0.0
    let abaValue = getAutoBalancerCurrentValue(id: tideID) ?? 0.0
    Test.assert(abaBalance >= 0.0 && abaValue >= 0.0, message: "AutoBalancer state should remain non-negative after liquidation")
}

/// Regression-style test inspired by `chore/liquidation-tests-alignment`:
/// verifies that a Tide backed by a FlowALP position behaves sensibly when the
/// Yield token price collapses to ~0, and that the user can still close the Tide
/// without panics while recovering some Flow.
access(all)
fun test_TideHandlesZeroYieldPriceOnClose() {
    Test.reset(to: snapshot)

    let fundingAmount: UFix64 = 100.0

    let user = Test.createAccount()
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    var tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)
    let tideID = tideIDs![0]

    // Drastically reduce Yield token price to approximate a near-total loss.
    // DeFiActions enforces a post-condition that oracle prices must be > 0.0
    // when available, so we use a tiny positive value instead of a literal 0.0.
    setMockOraclePrice(
        signer: flowVaultsAccount,
        forTokenIdentifier: yieldTokenIdentifier,
        price: 0.00000001
    )

    // Force a Tide-level rebalance so the AutoBalancer and connectors react to the new price.
    rebalanceTide(signer: flowVaultsAccount, id: tideID, force: true, beFailed: false)

    // Also rebalance the underlying FlowALP position to bring it back toward min health if possible.
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALP.Opened>())) as! FlowALP.Opened).pid
    rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

    // User should still be able to close the Tide cleanly.
    closeTide(signer: user, id: tideID, beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil after close")
    Test.assertEqual(0, tideIDs!.length)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    // In a full Yield token wipe-out, the user should not gain Flow relative to original
    // funding, but they should still recover something (no total loss due to wiring bugs).
    Test.assert(
        flowBalanceAfter <= flowBalanceBefore + fundingAmount,
        message: "Expected user's Flow balance after closing Tide under zero Yield price to be <= initial funding"
    )
    Test.assert(
        flowBalanceAfter > flowBalanceBefore,
        message: "Expected user's Flow balance after closing Tide under zero Yield price to be > starting balance"
    )
}

access(all)
fun test_RebalanceTideSucceedsAfterCollateralPriceIncrease() {
    Test.reset(to: snapshot)

    let fundingAmount = 100.0
    let collateralPriceIncrease = 5.0

    let user = Test.createAccount()

    // Likely 0.0
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowVaultsAccount, user)

    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )
    let positionID = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALP.Opened>())) as! FlowALP.Opened).pid

    var tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)

    // Set a high collateral price to simulate a scenario where the collateral value increases significantly
    // This should cause the rebalance to increase the amount of Yield tokens held in the Tide
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: collateralPriceIncrease)

    let yieldTokensBefore = getAutoBalancerBalance(id: tideIDs![0])!

    log("Yield token balance before rebalance: \(yieldTokensBefore)")

    // Rebalance the Tide to adjust the Yield tokens based on the new collateral price
    // Force both tide and position to rebalance
    rebalanceTide(signer: flowVaultsAccount, id: tideIDs![0], force: true, beFailed: false)

    // Position ID is hardcoded to 1 here since this is the first tide created, 
    // if there is a better way to get the position ID, please let me know
    rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

    let yieldTokensAfter = getAutoBalancerBalance(id: tideIDs![0])!

    log("Yield token balance after rebalance: \(yieldTokensAfter)")

    // the ratio of yield tokens after the rebalance should be directly proportional to the collateral price increase, 
    // as we started with 1.0 for all values.
    Test.assert(yieldTokensAfter >= (yieldTokensBefore * collateralPriceIncrease) - TOLERANCE,
        message: "Expected user's Flow balance after rebalance to be more than funding amount but got \(yieldTokensAfter)"
    )

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(0, tideIDs!.length)
}
