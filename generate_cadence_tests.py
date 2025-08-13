#!/usr/bin/env python3
"""
Cadence Test Generator for Tidal Protocol
Generates Cadence test files from CSV scenario data for fuzzy testing.

Outputs tests under `cadence/tests/generated/` and a runner to invoke them.
"""

import pandas as pd
from pathlib import Path
from decimal import Decimal, getcontext, ROUND_HALF_UP


getcontext().prec = 28
DP8 = Decimal('0.00000001')

def format_decimal(value):
    try:
        d = Decimal(str(value))
        return format(d.quantize(DP8, rounding=ROUND_HALF_UP), 'f')
    except Exception:
        return str(value)


def generate_test_header():
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

// Inline helper for generated tests
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            if balance.direction.rawValue == 1 {  // Debit = 1
                return balance.balance
            }
        }
    }
    return 0.0
}

// Inline helper for generated tests (align with legacy tests)
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means collateral deposit
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

// Debug helper to log per-step comparisons (machine-parsable)
access(all) fun logStep(_ label: String, _ i: Int, _ actualDebt: UFix64, _ expectedDebt: UFix64, _ actualY: UFix64, _ expectedY: UFix64, _ actualColl: UFix64, _ expectedColl: UFix64) {
    log("DRIFT|\(label)|\(i)|\(actualDebt)|\(expectedDebt)|\(actualY)|\(expectedY)|\(actualColl)|\(expectedColl)")
}

access(all)
fun setup() {
	deployContracts()

	// set mocked token prices
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	setupMoetVault(protocolAccount, beFailed: false)
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


def generate_standard_test(scenario_name: str, df: pd.DataFrame) -> str:
    test_name = f"test_RebalanceTide{scenario_name}"
    
    flow_prices = df['FlowPrice'].tolist() if 'FlowPrice' in df.columns else [1.0] * len(df)
    yield_prices = df['YieldPrice'].tolist() if 'YieldPrice' in df.columns else [1.0] * len(df)
    expected_debts = df['Debt'].tolist()
    expected_yields = df['YieldUnits'].tolist()
    expected_collaterals = df['Collateral'].tolist()
    has_actions = 'Actions' in df.columns
    actions = df['Actions'].fillna('none').tolist() if has_actions else []
    
    return f'''
access(all)
fun {test_name}() {{
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [{', '.join(format_decimal(p) for p in flow_prices)}]
    let yieldPrices = [{', '.join(format_decimal(p) for p in yield_prices)}]
    let expectedDebts = [{', '.join(format_decimal(d) for d in expected_debts)}]
    let expectedYieldUnits = [{', '.join(format_decimal(y) for y in expected_yields)}]
    let expectedCollaterals = [{', '.join(format_decimal(c) for c in expected_collaterals)}]
    let actions: [String] = [{', '.join('"' + str(a).replace('"','') + '"' for a in actions)}]

    // Keep initial prices at 1.0/1.0 for opening the Tide to match baseline CSV state

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
    var pid  = 1 as UInt64
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)

    // Initial stabilization
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

    // Step 0: set prices to step-0, execute CSV actions (if provided) in-order, then assert
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[0])
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[0])
    if {str(has_actions).lower()} {{
        let a0 = actions[0]
        if a0 != "none" {{
            let parts0 = a0.split(separator: "|")
            var j0: Int = 0
            while j0 < parts0.length {{
                let p0 = parts0[j0]
                if p0.contains("Bal") {{
                    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                }} else if p0.contains("Borrow") || p0.contains("Repay") {{
                    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
                }}
                j0 = j0 + 1
            }}
        }}
    }}

    var allGood: Bool = true
    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("{scenario_name}", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    let okDebt0 = equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001)
    let okY0 = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001)
    let okC0 = equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001)
    if !(okDebt0 && okY0 && okC0) {{ allGood = false }}

    // Subsequent steps: set prices, rebalance, assert
    var i = 1
    while i < flowPrices.length {{
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])

        // Execute rebalances per CSV 'Actions' for this step in-order if available; otherwise run Tide once
        if {str(has_actions).lower()} {{
            let a = actions[i]
            if a != "none" {{
                let parts = a.split(separator: "|")
                var idx: Int = 0
                while idx < parts.length {{
                    let p = parts[idx]
                    if p.contains("Bal") {{
                        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                    }} else if p.contains("Borrow") || p.contains("Repay") {{
                        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
                    }} else {{
                        // Default to Tide rebalance if action token is unrecognized
                        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                    }}
                    idx = idx + 1
                }}
            }} else {{
                rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            }}
        }} else {{
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        }}

        actualDebt = getMOETDebtFromPosition(pid: pid)
        actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
        actualCollateral = flowCollateralAmount * flowPrices[i]

        logStep("{scenario_name}", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        let okDebt = equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001)
        let okY = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001)
        let okC = equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001)
        if !(okDebt && okY && okC) {{ allGood = false }}
        i = i + 1
    }}

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
    Test.assert(allGood, message: "One or more steps exceeded tolerance")
}}
'''


def generate_instant_rebalance_test(scenario_name: str, df: pd.DataFrame) -> str:
    """Generate tests that always rebalance immediately after setting prices.
    Intended for CSVs where expected values are post-rebalance (e.g., Scenario1 FLOW grid).
    Expects columns: FlowPrice, YieldPrice, Debt, YieldUnits, Collateral.
    """
    test_name = f"test_RebalanceTide{scenario_name}"

    flow_prices = df['FlowPrice'].tolist() if 'FlowPrice' in df.columns else [1.0] * len(df)
    yield_prices = df['YieldPrice'].tolist() if 'YieldPrice' in df.columns else [1.0] * len(df)
    expected_debts = df['Debt'].tolist()
    expected_yields = df['YieldUnits'].tolist()
    expected_collaterals = df['Collateral'].tolist()

    return f'''
access(all)
fun {test_name}() {{
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [{', '.join(format_decimal(p) for p in flow_prices)}]
    let yieldPrices = [{', '.join(format_decimal(p) for p in yield_prices)}]
    let expectedDebts = [{', '.join(format_decimal(d) for d in expected_debts)}]
    let expectedYieldUnits = [{', '.join(format_decimal(y) for y in expected_yields)}]
    let expectedCollaterals = [{', '.join(format_decimal(c) for c in expected_collaterals)}]

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
    var pid  = 1 as UInt64
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)

    // Initial stabilization
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)

    var allGood: Bool = true

    // Step 0: set prices, rebalance both, then assert post-rebalance values
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[0])
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[0])
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)

    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("{scenario_name}", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    let okDebt0 = equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001)
    let okY0 = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001)
    let okC0 = equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001)
    if !(okDebt0 && okY0 && okC0) {{ allGood = false }}

    // Subsequent steps: set prices, rebalance both, assert
    var i = 1
    while i < flowPrices.length {{
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])
        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

        actualDebt = getMOETDebtFromPosition(pid: pid)
        actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
        actualCollateral = flowCollateralAmount * flowPrices[i]

        logStep("{scenario_name}", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        let okDebt = equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001)
        let okY = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001)
        let okC = equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001)
        if !(okDebt && okY && okC) {{ allGood = false }}
        i = i + 1
    }}

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
    Test.assert(allGood, message: "One or more steps exceeded tolerance")
}}
'''


def generate_path_test(scenario_name: str, df: pd.DataFrame) -> str:
    """Generate sequential path test matching legacy step semantics.
    Expects columns: Step, Label, FlowPrice, YieldPrice, Debt, YieldUnits, Collateral.
    Semantics:
      - Step 0 (start): no rebalance after price set; just validate initial state
      - Step 1 (after FLOW): set FlowPrice, rebalance tide + protocol, validate
      - Step 2 (after YIELD): set YieldPrice, rebalance tide only (not protocol), validate
    """
    test_name = f"test_RebalanceTide{scenario_name}"
    
    # Ensure deterministic ordering by Step
    df = df.sort_values(by=['Step']).reset_index(drop=True)

    steps = []
    for _, row in df.iterrows():
        steps.append({
            'label': str(row.get('Label', '')),
            'flow': format_decimal(row['FlowPrice']),
            'yield': format_decimal(row['YieldPrice']),
            'debt': format_decimal(row['Debt']),
            'yieldUnits': format_decimal(row['YieldUnits']),
            'collateral': format_decimal(row['Collateral']),
        })

    code = []
    code.append(f"access(all)\nfun {test_name}() {{")
    code.append("\tlet fundingAmount = 1000.0")
    code.append("\tlet user = Test.createAccount()")
    code.append("\tlet flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!\n\tmintFlow(to: user, amount: fundingAmount)")
    code.append("\tcreateTide(\n\t\tsigner: user,\n\t\tstrategyIdentifier: strategyIdentifier,\n\t\tvaultIdentifier: flowTokenIdentifier,\n\t\tamount: fundingAmount,\n\t\tbeFailed: false\n\t)")
    code.append("\tvar tideIDs = getTideIDs(address: user.address)\n\tvar pid  = 1 as UInt64\n\tTest.assert(tideIDs != nil, message: \"Expected user's Tide IDs to be non-nil but encountered nil\")\n\tTest.assertEqual(1, tideIDs!.length)")

    # Initial stabilization
    code.append("\trebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)")

    # Step 0: baseline (no rebalance after set)
    s0 = steps[0]
    code.append(f"\t// Step 0: {s0['label']}")
    code.append(f"\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: {s0['flow']})")
    code.append(f"\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: {s0['yield']})")
    code.append("\tvar actualDebt = getMOETDebtFromPosition(pid: pid)")
    code.append("\tvar actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0")
    code.append(f"\tvar flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)\n\tvar actualCollateral = flowCollateralAmount * {s0['flow']}")
    code.append(f"\tlogStep(\"{scenario_name}\", 0, actualDebt, {s0['debt']}, actualYieldUnits, {s0['yieldUnits']}, actualCollateral, {s0['collateral']})")
    code.append(f"\tTest.assert(equalAmounts(a: actualDebt, b: {s0['debt']}, tolerance: 0.0000001), message: \"Debt mismatch at step 0\")")
    code.append(f"\tTest.assert(equalAmounts(a: actualYieldUnits, b: {s0['yieldUnits']}, tolerance: 0.0000001), message: \"Yield mismatch at step 0\")")
    code.append(f"\tTest.assert(equalAmounts(a: actualCollateral, b: {s0['collateral']}, tolerance: 0.0000001), message: \"Collateral mismatch at step 0\")")

    # Step 1..N-1
    for idx, s in enumerate(steps[1:], start=1):
        code.append(f"\n\t// Step {idx}: {s['label']}")
        code.append(f"\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: {s['flow']})")
        code.append(f"\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: {s['yield']})")
        # Always use Tide rebalance; ensure one protocol sync in FLOW step for legacy parity
        code.append("\trebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)")
        code.append("\trebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)")
        code.append("\tactualDebt = getMOETDebtFromPosition(pid: pid)")
        code.append("\tactualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0")
        code.append(f"\tflowCollateralAmount = getFlowCollateralFromPosition(pid: pid)\n\tactualCollateral = flowCollateralAmount * {s['flow']}")
        code.append(f"\tlogStep(\"{scenario_name}\", {idx}, actualDebt, {s['debt']}, actualYieldUnits, {s['yieldUnits']}, actualCollateral, {s['collateral']})")
        code.append(f"\tTest.assert(equalAmounts(a: actualDebt, b: {s['debt']}, tolerance: 0.0000001), message: \"Debt mismatch at step {idx}\")")
        code.append(f"\tTest.assert(equalAmounts(a: actualYieldUnits, b: {s['yieldUnits']}, tolerance: 0.0000001), message: \"Yield mismatch at step {idx}\")")
        code.append(f"\tTest.assert(equalAmounts(a: actualCollateral, b: {s['collateral']}, tolerance: 0.0000001), message: \"Collateral mismatch at step {idx}\")")

    code.append("\tcloseTide(signer: user, id: tideIDs![0], beFailed: false)")
    code.append("\tlet flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!\n\tTest.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: \"Expected user's Flow balance > 0 after test\")")
    code.append("}")

    return "\n".join(code)


def generate_multi_path_test(scenario_name: str, df: pd.DataFrame) -> str:
    # Emit independent top-level tests per PathName
    blocks = []
    for path in df['PathName'].unique():
        sub = df[df['PathName'] == path]
        blocks.append(generate_standard_test(f"{scenario_name}_{path}", sub))
    return '\n\n'.join(blocks)


def generate_edge_case_test(scenario_name: str, df: pd.DataFrame) -> str:
    # Emit independent top-level tests per TestCase
    blocks = []
    for _, row in df.iterrows():
        sub = pd.DataFrame([row])
        blocks.append(generate_standard_test(f"{scenario_name}_{row['TestCase']}", sub))
    return '\n\n'.join(blocks)


def generate_scaling_test(scenario_name: str, df: pd.DataFrame) -> str:
    """Generate scaling tests: emit one top-level test per row to ensure fresh setup per case.
    Expects columns: InitialFLOW, Collateral, Debt, YieldUnits, Health
    """
    rows = []
    for _, row in df.iterrows():
        rows.append({
            'initialFlow': format_decimal(row['InitialFLOW']),
            'collateral': format_decimal(row['Collateral']),
            'debt': format_decimal(row['Debt']),
            'yieldUnits': format_decimal(row['YieldUnits']),
        })

    code_blocks = []
    for idx, r in enumerate(rows):
        n = idx + 1
        test_name = f"test_RebalanceTide{scenario_name}_Case{n}"
        cb = []
        cb.append(f"access(all)\nfun {test_name}() {{")
        cb.append("\t// Reset to initial post-deploy snapshot if available")
        cb.append("\tif (snapshot > 0) { Test.reset(to: snapshot) }")
        cb.append("\t// Prices fixed at 1.0 for scaling baseline")
        cb.append("\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)")
        cb.append("\tsetMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)")
        cb.append(f"\tlet user = Test.createAccount()")
        cb.append(f"\tlet flowBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!\n\tmintFlow(to: user, amount: {r['initialFlow']})")
        cb.append(f"\tcreateTide(\n\t\tsigner: user,\n\t\tstrategyIdentifier: strategyIdentifier,\n\t\tvaultIdentifier: flowTokenIdentifier,\n\t\tamount: {r['initialFlow']},\n\t\tbeFailed: false\n\t)")
        cb.append(f"\tvar tideIDs = getTideIDs(address: user.address)\n\tvar pid: UInt64 = 1\n\tTest.assert(tideIDs != nil, message: \"tideIDs nil\")\n\tTest.assertEqual(1, tideIDs!.length)")
        cb.append(f"\trebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)")
        cb.append(f"\tlet debt = getMOETDebtFromPosition(pid: pid)")
        cb.append(f"\tlet y = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0")
        cb.append(f"\tlet flowAmt = getFlowCollateralFromPosition(pid: pid)")
        cb.append(f"\tlet coll = flowAmt * 1.0")
        cb.append(f"\tTest.assert(equalAmounts(a: debt, b: {r['debt']}, tolerance: 0.0000001), message: \"Debt mismatch for case {n}\")")
        cb.append(f"\tTest.assert(equalAmounts(a: y, b: {r['yieldUnits']}, tolerance: 0.0000001), message: \"Yield mismatch for case {n}\")")
        cb.append(f"\tTest.assert(equalAmounts(a: coll, b: {r['collateral']}, tolerance: 0.0000001), message: \"Collateral mismatch for case {n}\")")
        cb.append(f"\tcloseTide(signer: user, id: tideIDs![0], beFailed: false)")
        cb.append("}")
        code_blocks.append('\n'.join(cb))

    return '\n\n'.join(code_blocks)


def generate_random_walk_test(scenario_name: str, df: pd.DataFrame) -> str:
    # Emit independent top-level tests per walk
    blocks = []
    for walk_id in df['WalkID'].unique():
        sub = df[df['WalkID'] == walk_id]
        blocks.append(generate_standard_test(f"{scenario_name}_Walk{int(walk_id)}", sub))
    return '\n\n'.join(blocks)


def generate_shocks_test(scenario_name: str, df: pd.DataFrame) -> str:
    # Emit independent top-level tests per shock type
    blocks = []
    for shock in df['Shock'].unique():
        sub = df[df['Shock'] == shock]
        blocks.append(generate_standard_test(f"{scenario_name}_{shock}", sub))
    return '\n\n'.join(blocks)


def generate_scenario_test(scenario_name: str, csv_path: Path) -> str:
    df = pd.read_csv(csv_path)
    if 'Step' in df.columns and 'Label' in df.columns and 'FlowPrice' in df.columns and 'YieldPrice' in df.columns:
        # Legacy path-style scenario (A/B/C/D) with specific step semantics
        return generate_path_test(scenario_name, df)
    if 'InitialFLOW' in df.columns and 'Debt' in df.columns and 'YieldUnits' in df.columns:
        return generate_scaling_test(scenario_name, df)
    if 'WalkID' in df.columns:
        # If this CSV contains a single walk, emit a single test without extra suffix
        try:
            if df['WalkID'].nunique() == 1:
                return generate_standard_test(scenario_name, df)
        except Exception:
            pass
        # Otherwise, emit a test per-walk from the combined file
        return generate_random_walk_test(scenario_name, df)
    if 'TestCase' in df.columns:
        return generate_edge_case_test(scenario_name, df)
    if 'PathName' in df.columns:
        # Legacy combined file; we now split per path at CSV level
        return generate_multi_path_test(scenario_name, df)
    if 'Shock' in df.columns:
        return generate_shocks_test(scenario_name, df)
    if 'DebtBefore' in df.columns and 'DebtAfter' in df.columns:
        # Scenario 1 format: expected values are post-rebalance after price set
        mapped = pd.DataFrame({
            'FlowPrice': df['FlowPrice'],
            'YieldPrice': 1.0,
            'Debt': df['DebtAfter'],
            'YieldUnits': df['YieldAfter'],
            'Collateral': df['Collateral'],
        })
        return generate_instant_rebalance_test(scenario_name, mapped)
    return generate_standard_test(scenario_name, df)


def main():
    scenarios = {
        'Scenario1_FLOW': 'Scenario1_FLOW.csv',
        'Scenario2_Instant': 'Scenario2_Instant.csv',
        'Scenario3_Path_A': 'Scenario3_Path_A_precise.csv',
        'Scenario3_Path_B': 'Scenario3_Path_B_precise.csv',
        'Scenario3_Path_C': 'Scenario3_Path_C_precise.csv',
        'Scenario3_Path_D': 'Scenario3_Path_D_precise.csv',
        # Compact numbering after removing Scenario4_Scaling from CSVs
        'Scenario4_VolatileMarkets': 'Scenario4_VolatileMarkets.csv',
        'Scenario5_GradualTrends': 'Scenario5_GradualTrends.csv',
        'Scenario6_EdgeCases': 'Scenario6_EdgeCases.csv',
        # Scenario7 split into per-path CSVs
        'Scenario7_MultiStepPaths_Bear': 'Scenario7_MultiStepPaths_Bear.csv',
        'Scenario7_MultiStepPaths_Bull': 'Scenario7_MultiStepPaths_Bull.csv',
        'Scenario7_MultiStepPaths_Sideways': 'Scenario7_MultiStepPaths_Sideways.csv',
        'Scenario7_MultiStepPaths_Crisis': 'Scenario7_MultiStepPaths_Crisis.csv',
        # Scenario8 split per-walk for independent setup
        'Scenario8_RandomWalks_Walk0': 'Scenario8_RandomWalks_Walk0.csv',
        'Scenario8_RandomWalks_Walk1': 'Scenario8_RandomWalks_Walk1.csv',
        'Scenario8_RandomWalks_Walk2': 'Scenario8_RandomWalks_Walk2.csv',
        'Scenario8_RandomWalks_Walk3': 'Scenario8_RandomWalks_Walk3.csv',
        'Scenario8_RandomWalks_Walk4': 'Scenario8_RandomWalks_Walk4.csv',
        # Scenario9 split into per-shock CSVs
        'Scenario9_ExtremeShocks_FlashCrash': 'Scenario9_ExtremeShocks_FlashCrash.csv',
        'Scenario9_ExtremeShocks_Rebound': 'Scenario9_ExtremeShocks_Rebound.csv',
        'Scenario9_ExtremeShocks_YieldHyperInflate': 'Scenario9_ExtremeShocks_YieldHyperInflate.csv',
        'Scenario9_ExtremeShocks_MixedShock': 'Scenario9_ExtremeShocks_MixedShock.csv',
    }
    
    out_dir = Path('cadence/tests')
    out_dir.mkdir(parents=True, exist_ok=True)
    
    for name, csv_file in scenarios.items():
        csv_path = Path(csv_file)
        if not csv_path.exists():
            print(f"Warning: {csv_file} not found, skipping…")
            continue
        content = generate_test_header() + generate_scenario_test(name, csv_path)
        test_filename = f"rebalance_{name.lower()}_test.cdc"
        (out_dir / test_filename).write_text(content)
        print(f"✓ Generated {test_filename}")
    
    print(f"All tests generated in: {out_dir}")


if __name__ == '__main__':
    main()
