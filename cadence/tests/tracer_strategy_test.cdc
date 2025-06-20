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

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // set mocked token prices
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // mint tokens & set liquidity in mock swapper contract
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: 100_000_00.0)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 100_000_00.0, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: 100_000_00.0, beFailed: false)
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
}

access(all)
fun test_RebalanceTideSucceeds() {
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

    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.1)

    log("Rebalancing Tide...")
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(0, tideIDs!.length)
}