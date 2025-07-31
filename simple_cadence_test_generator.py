#!/usr/bin/env python3
"""
Simple Cadence Test Generator for Tidal Protocol
Dynamically generates lean Cadence test files from CSV scenarios.
Uses CSV columns for inputs and expected values.
"""

import pandas as pd
from pathlib import Path
import argparse

def generate_test_header():
    """Generate standard Cadence test header with helpers."""
    return '''import Test
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
'''

def generate_test_body(csv_path, test_name, tolerance=0.00000001):
    df = pd.read_csv(csv_path)
    num_rows = len(df)
    body = f'access(all) fun {test_name}() {{ \n    // Test.reset(to: snapshot)\n    let user = Test.createAccount()\n    let fundingAmount = 1000.0\n    mintFlow(to: user, amount: fundingAmount)\n    createTide(signer: user, strategyIdentifier: strategyIdentifier, vaultIdentifier: flowTokenIdentifier, amount: fundingAmount, beFailed: false)\n    let tideIDs = getTideIDs(address: user.address)!\n    let pid = 1 as UInt64\n    rebalanceTide(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)\n    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)\n'
    has_step = 'Step' in df.columns
    has_flow_price = 'FlowPrice' in df.columns
    has_yield_price = 'YieldPrice' in df.columns
    has_expected_debt = 'Debt' in df.columns
    has_expected_yield = 'YieldUnits' in df.columns
    has_expected_collateral = 'Collateral' in df.columns
    body += f'    var i: Int = 0\n    while i < {num_rows} {{ \n'
    if has_step:
        body += '        log("Step \(i)")\n'
    if has_flow_price:
        flow_prices_str = '[' + ', '.join(str(round(float(v), 8)) for v in df['FlowPrice']) + ']'
        body += f'        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: {flow_prices_str}[i])\n'
    if has_yield_price:
        yield_prices_str = '[' + ', '.join(str(round(float(v), 8)) for v in df['YieldPrice']) + ']'
        body += f'        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: {yield_prices_str}[i])\n'
    body += '        rebalanceTide(signer: tidalYieldAccount, id: tideIDs[0], force: true, beFailed: false)\n'
    body += '        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)\n'
    body += '        let actualDebt = getMOETDebtFromPosition(pid: pid)\n'
    body += '        let actualYield = getYieldUnits(id: tideIDs[0])\n'
    body += '        let actualCollateral = getFlowCollateralValue(pid: pid, flowPrice:'
    if has_flow_price:
        body += f' {flow_prices_str}[i]'
    else:
        body += ' 1.0'
    body += ')\n'
    if has_expected_debt:
        debt_str = '[' + ', '.join(str(round(float(v), 8)) for v in df['Debt']) + ']'
        body += f'        let debtDiff = actualDebt > {debt_str}[i] ? actualDebt - {debt_str}[i] : {debt_str}[i] - actualDebt\n'
        body += f'        let debtSign = actualDebt > {debt_str}[i] ? "+" : "-"\n'
        body += f'        let debtPercent = ({debt_str}[i] > 0.0) ? (debtDiff / {debt_str}[i]) * 100.0 : 0.0\n'
        body += f'        log("Debt Diff: \(debtSign)\(debtDiff) (\(debtSign)\(debtPercent)%)\")\n'
        body += f'        Test.assert(equalAmounts(a: actualDebt, b: {debt_str}[i], tolerance: 0.00000001), message: "Debt mismatch at step \(i)")\n'
    if has_expected_yield:
        yield_str = '[' + ', '.join(str(round(float(v), 8)) for v in df['YieldUnits']) + ']'
        body += f'        let yieldDiff = actualYield > {yield_str}[i] ? actualYield - {yield_str}[i] : {yield_str}[i] - actualYield\n'
        body += f'        let yieldSign = actualYield > {yield_str}[i] ? "+" : "-"\n'
        body += f'        let yieldPercent = ({yield_str}[i] > 0.0) ? (yieldDiff / {yield_str}[i]) * 100.0 : 0.0\n'
        body += f'        log("Yield Diff: \(yieldSign)\(yieldDiff) (\(yieldSign)\(yieldPercent)%)\")\n'
        body += f'        Test.assert(equalAmounts(a: actualYield, b: {yield_str}[i], tolerance: 0.00000001), message: "Yield mismatch at step \(i)")\n'
    if has_expected_collateral:
        collateral_str = '[' + ', '.join(str(round(float(v), 8)) for v in df['Collateral']) + ']'
        body += f'        let collDiff = actualCollateral > {collateral_str}[i] ? actualCollateral - {collateral_str}[i] : {collateral_str}[i] - actualCollateral\n'
        body += f'        let collSign = actualCollateral > {collateral_str}[i] ? "+" : "-"\n'
        body += f'        let collPercent = ({collateral_str}[i] > 0.0) ? (collDiff / {collateral_str}[i]) * 100.0 : 0.0\n'
        body += f'        log("Collateral Diff: \(collSign)\(collDiff) (\(collSign)\(collPercent)%)\")\n'
        body += f'        Test.assert(equalAmounts(a: actualCollateral, b: {collateral_str}[i], tolerance: 0.00000001), message: "Collateral mismatch at step \(i)")\n'
    body += '        i = i + 1\n    }\n    // closeTide(signer: user, id: tideIDs[0], beFailed: false)\n}\n'
    return body

def main():
    parser = argparse.ArgumentParser(description='Generate Cadence test from CSV.')
    parser.add_argument('csv_path', help='Path to scenario CSV file')
    parser.add_argument('--output', default='cadence/tests/generated_test.cdc', help='Output Cadence file path')
    parser.add_argument('--tolerance', type=float, default=0.00000001, help='Assertion tolerance')
    args = parser.parse_args()

    test_name = f'test_{Path(args.csv_path).stem}'
    header = generate_test_header()
    body = generate_test_body(args.csv_path, test_name, args.tolerance)
    full_test = header + body

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        f.write(full_test)
    print(f'Generated test file: {output_path}')

if __name__ == '__main__':
    main() 