import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalYieldStrategies"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@TidalYieldStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // set mocked token prices
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // mint tokens & set liquidity in mock swapper contract
    let reserveAmount = 100_000_00.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // setup TidalProtocol with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // open wrapped position (pushToDrawDownSink)
    // the equivalent of depositing reserves
    let openRes = executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // enable mocked Strategy creation
    addStrategyComposer(signer: tidalYieldAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
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
    let priceIncrease = 1.5

    let user = Test.createAccount()

    // Likely 0.0
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    mintFlow(to: user, amount: fundingAmount)

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

    var tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

    log("Tide balance before yield increase: \(tideBalance ?? 0.0)")

    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: priceIncrease)

    tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

    log("Tide balance before rebalance: \(tideBalance ?? 0.0)")

    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: 1, force: true, beFailed: false)


    let positionDetails = getPositionDetails(pid: 1, beFailed: false)

    let positionFlowBalance = positionDetails.balances[1]
    log(positionFlowBalance)

    // The math here is a little off, expected amount is around 130, but the final value of the tide is 127
    let initialLoan = fundingAmount * (collateralFactor / targetHealthFactor)
    let expectedBalance = (initialLoan * priceIncrease - initialLoan) + fundingAmount
    log("Position Flow balance after rebalance: \(positionFlowBalance.balance)")
    Test.assert(positionFlowBalance.balance > fundingAmount,
        message: "Expected user's Flow balance in their position after rebalance to be more than \(fundingAmount) but got \(positionFlowBalance.balance)"
    )

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

    var tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

    log("Tide balance before yield increase: \(tideBalance ?? 0.0)")

    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: priceDecrease)

    tideBalance = getTideBalance(address: user.address, tideID: tideIDs![0])

    log("Tide balance before rebalance: \(tideBalance ?? 0.0)")

    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(0, tideIDs!.length)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let expectedBalance = fundingAmount * 0.5
    Test.assert((flowBalanceAfter-flowBalanceBefore) <= expectedBalance,
        message: "Expected user's Flow balance after rebalance to be less than the original, due to decrease in yield price but got \(flowBalanceAfter)")

    Test.assert((flowBalanceAfter-flowBalanceBefore) > 0.1,
        message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
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

    // Set a high collateral price to simulate a scenario where the collateral value increases significantly
    // This should cause the rebalance to increase the amount of Yield tokens held in the Tide
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: collateralPriceIncrease)

    let yieldTokensBefore = getAutoBalancerBalance(address: user.address, id: tideIDs![0])!

    log("Yield token balance before rebalance: \(yieldTokensBefore)")

    // Rebalance the Tide to adjust the Yield tokens based on the new collateral price
    // Force both tide and position to rebalance
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)

    // Position ID is hardcoded to 1 here since this is the first tide created, 
    // if there is a better way to get the position ID, please let me know
    rebalancePosition(signer: protocolAccount, pid: 1, force: true, beFailed: false)

    let yieldTokensAfter = getAutoBalancerBalance(address: user.address, id: tideIDs![0])!

    log("Yield token balance after rebalance: \(yieldTokensAfter)")

    // the ratio of yield tokens after the rebalance should be directly proportional to the collateral price increase, 
    // as we started with 1.0 for all values.
    Test.assert(yieldTokensAfter >= (yieldTokensBefore * collateralPriceIncrease),
        message: "Expected user's Flow balance after rebalance to be more than funding amount but got \(yieldTokensAfter)"
    )

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(0, tideIDs!.length)
}