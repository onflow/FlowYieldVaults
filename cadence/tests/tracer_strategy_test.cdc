import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowALPv0"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
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
		composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
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

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultID, force: true, beFailed: false)

    // TODO - assert against pre- and post- getYieldVaultBalance() diff once protocol assesses balance correctly
    //      for now we can use events to intercept fund flows between pre- and post- Position & AutoBalancer state

    // assess how much FLOW was deposited into the position
    let autoBalancerRecollateralizeEvent = getLastPositionDepositedEvent(Test.eventsOfType(Type<FlowALPv0.Deposited>())) as! FlowALPv0.Deposited
    Test.assertEqual(positionID, autoBalancerRecollateralizeEvent.pid)
    Test.assertEqual(autoBalancerRecollateralizeEvent.amount,
        (autoBalancerValueAfter - autoBalancerValueBefore) / startingFlowPrice
    )

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

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: positionID, force: true, beFailed: false)

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(0, yieldVaultIDs!.length)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	let expectedBalance = fundingAmount * 0.5
	Test.assert((flowBalanceAfter-flowBalanceBefore) <= expectedBalance,
	message: "Expected user's Flow balance after rebalance to be less than the original, due to decrease in yield price but got \(flowBalanceAfter)")

	Test.assert(
		(flowBalanceAfter-flowBalanceBefore) > 0.1,
		message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	)
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

    // Rebalance the YieldVault to adjust the Yield tokens based on the new collateral price
    // Force both yield vault and position to rebalance
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

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
