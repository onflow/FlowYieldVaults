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

// Helper to get MOET debt
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() && balance.direction.rawValue == 1 {
            return balance.balance
        }
    }
    return 0.0
}

// Helper to get Yield units from auto-balancer
access(all) fun getYieldUnits(id: UInt64): UFix64 {
    return getAutoBalancerBalance(id: id) ?? 0.0
}

// Helper to get Flow collateral value
access(all) fun getFlowCollateralValue(pid: UInt64, flowPrice: UFix64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() && balance.direction.rawValue == 0 {
            return balance.balance * flowPrice
        }
    }
    return 0.0
}

access(all) fun setup() {
    deployContracts()
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    let reserveAmount = 10000000.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    let openRes = executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
    snapshot = getCurrentBlockHeight()
}
access(all) fun test_Scenario5_VolatileMarkets() { 
    // Test.reset(to: snapshot)
    let user = Test.createAccount()
    let fundingAmount = 1000.0
    mintFlow(to: user, amount: fundingAmount)
    createTide(signer: user, strategyIdentifier: strategyIdentifier, vaultIdentifier: flowTokenIdentifier, amount: fundingAmount, beFailed: false)
    let tideIDs = getTideIDs(address: user.address)!
    let pid = 1 as UInt64
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
    var i: Int = 0
    while i < 10 { 
        log("Step \(i)")
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: [1.0, 1.8, 0.6, 2.2, 0.4, 3.0, 1.0, 0.2, 4.0, 1.5][i])
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: [1.0, 1.2, 1.5, 1.5, 2.5, 2.5, 3.5, 3.5, 4.0, 4.0][i])
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        let actualDebt = getMOETDebtFromPosition(pid: pid)
        let actualYield = getYieldUnits(id: tideIDs[0])
        let actualCollateral = getFlowCollateralValue(pid: pid, flowPrice: [1.0, 1.8, 0.6, 2.2, 0.4, 3.0, 1.0, 0.2, 4.0, 1.5][i])
        let debtDiff = actualDebt > [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i] ? actualDebt - [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i] : [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i] - actualDebt
        let debtSign = actualDebt > [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i] ? "+" : "-"
        let debtPercent = ([615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i] > 0.0) ? (debtDiff / [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i]) * 100.0 : 0.0
        log("Debt Diff: \(debtSign)\(debtDiff) (\(debtSign)\(debtPercent)%)")
        Test.assert(equalAmounts(a: actualDebt, b: [615.38461538, 1183.43195266, 576.54377181, 2113.99382997, 1251.64203453, 9387.31525897, 5439.82884238, 1087.96576848, 21854.96071179, 8195.61026692][i], tolerance: 0.00000001), message: "Debt mismatch at step \(i)")
        let yieldDiff = actualYield > [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i] ? actualYield - [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i] : [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i] - actualYield
        let yieldSign = actualYield > [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i] ? "+" : "-"
        let yieldPercent = ([615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i] > 0.0) ? (yieldDiff / [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i]) * 100.0 : 0.0
        log("Yield Diff: \(yieldSign)\(yieldDiff) (\(yieldSign)\(yieldPercent)%)")
        Test.assert(equalAmounts(a: actualYield, b: [615.38461538, 986.19329389, 384.36251454, 1409.32921998, 500.65681381, 3754.92610359, 1554.23681211, 310.84736242, 5463.74017795, 2048.90256673][i], tolerance: 0.00000001), message: "Yield mismatch at step \(i)")
        let collDiff = actualCollateral > [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i] ? actualCollateral - [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i] : [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i] - actualCollateral
        let collSign = actualCollateral > [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i] ? "+" : "-"
        let collPercent = ([1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i] > 0.0) ? (collDiff / [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i]) * 100.0 : 0.0
        log("Collateral Diff: \(collSign)\(collDiff) (\(collSign)\(collPercent)%)")
        Test.assert(equalAmounts(a: actualCollateral, b: [1000.0, 1923.07692308, 936.88362919, 3435.2399737, 2033.91830611, 15254.38729582, 8839.72186886, 1767.94437377, 35514.31115665, 13317.86668375][i], tolerance: 0.00000001), message: "Collateral mismatch at step \(i)")
        i = i + 1
    }
    // closeTide(signer: user, id: tideIDs[0], beFailed: false)
}
