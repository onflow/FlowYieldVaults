import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalProtocol"import "TidalYieldStrategiesV2"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@TidalYieldStrategiesV2.TracerStrategyV2>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContractsV2()
    
    // set mocked token prices
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // mint tokens & set liquidity in mock swapper contract
    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: Test.getAccount(0x0000000000000008), to: protocolAccount.address, amount: reserveAmount, beFailed: false)
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

    // open wrapped position
    let openRes = executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // enable mocked Strategy creation for V2
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@TidalYieldStrategiesV2.TracerStrategyComposerV2>().identifier,
        issuerStoragePath: TidalYieldStrategiesV2.IssuerStoragePath,
        beFailed: false
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_RebalanceTideScenario3D_V2() {
    let fundingAmount = 1000.0
    let flowPriceDecrease = 0.5
    let yieldPriceIncrease = 1.5

    let expectedYieldTokenValues = [615.38461538, 307.69230769, 268.24457594]

    let user = Test.createAccount()

    mintFlow(to: user, amount: fundingAmount)

    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    let tideIDs = getTideIDs(address: user.address)!
    let pid: UInt64 = 1

    log("[V2 TEST] Tide ID: \(tideIDs[0])")

    rebalanceTideV2(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)

    let yieldTokensBefore = getAutoBalancerBalanceV2(id: tideIDs[0])!
    log("\n=== V2 PRECISION COMPARISON (Before Flow Price Decrease) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
    log("Actual Yield Tokens:   \(yieldTokensBefore)")
    let diff0 = yieldTokensBefore > expectedYieldTokenValues[0] ? yieldTokensBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - yieldTokensBefore
    let sign0 = yieldTokensBefore > expectedYieldTokenValues[0] ? "+" : "-"
    log("Difference:            \(sign0)\(diff0)")
    log("===========================================================\n")
    
    Test.assert(
        equalAmounts(a: yieldTokensBefore, b: expectedYieldTokenValues[0], tolerance: 0.01),
        message: "V2: Expected yield tokens before to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
    )

    rebalanceTideV2(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalanceV2(id: tideIDs[0])!
    log("\n=== V2 PRECISION COMPARISON (After Flow Price Decrease) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
    log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceDecrease)")
    let diff1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceDecrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceDecrease
    let sign1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? "+" : "-"
    log("Difference:            \(sign1)\(diff1)")
    log("===========================================================\n")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterFlowPriceDecrease, b: expectedYieldTokenValues[1], tolerance: 0.01),
        message: "V2: Expected yield tokens after flow decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
    )

    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

    rebalanceTideV2(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)

    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalanceV2(id: tideIDs[0])!
    log("\n=== V2 PRECISION COMPARISON (After Yield Price Increase) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
    log("Actual Yield Tokens:   \(yieldTokensAfterYieldPriceIncrease)")
    let diff2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? yieldTokensAfterYieldPriceIncrease - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - yieldTokensAfterYieldPriceIncrease
    let sign2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? "+" : "-"
    log("Difference:            \(sign2)\(diff2)")
    log("===========================================================\n")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterYieldPriceIncrease, b: expectedYieldTokenValues[2], tolerance: 0.01),
        message: "V2: Expected yield tokens after yield increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
    )

    log("[V2 TEST] Closing tide...")
    closeTide(signer: user, id: tideIDs[0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("[V2 TEST] Flow balance after: \(flowBalanceAfter)")
} 