
import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
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
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // mint tokens & set liquidity in mock swapper contract
    let reserveAmount = 100_000_00.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // setup FlowCreditMarket with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        yearlyRate: UFix128(0.0),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // open wrapped position (pushToDrawDownSink)
    // the equivalent of depositing reserves
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/transactions/flow-credit-market/position/create_position.cdc",
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
fun test_RebalanceYieldVaultScenario2() {
    // Test.reset(to: snapshot)

    let fundingAmount = 1625.0

    let user = Test.createAccount()

    let yieldPriceIncreases = [1.1]
    let expectedFlowBalance = [
    1725.0
    ]

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

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    var pid  = 1 as UInt64
    log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

    log("[TEST] Initial yield vault balance: \(yieldVaultBalance ?? 0.0)")

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

    for index, yieldTokenPrice in yieldPriceIncreases {
        yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

        log("[TEST] YieldVault balance before yield price \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

        setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldTokenPrice)

        yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

        log("[TEST] YieldVault balance before yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

        rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: false, beFailed: false)

        yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

        log("[TEST] YieldVault balance after yield before \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

        Test.assert(
            yieldVaultBalance == expectedFlowBalance[index],
            message: "YieldVault balance of \(yieldVaultBalance ?? 0.0) doesn't match an expected value \(expectedFlowBalance[index])"
        )
    }

    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("[TEST] flow balance after \(flowBalanceAfter)")

    Test.assert(
        equalAmounts(a: flowBalanceAfter, b: expectedFlowBalance[0], tolerance: 0.01),
        message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
    )
}

