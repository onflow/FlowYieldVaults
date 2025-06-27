#!/usr/bin/env python3
"""
Tidal Protocol Mixed Price Scenario Test Runner
Supports different prices for FLOW and YieldToken in the same test
"""

import argparse
import subprocess
import sys
import os
import json

def generate_mixed_test_file(flow_prices, yield_prices, descriptions, scenario_name):
    """Generate a Cadence test file with mixed price scenarios"""
    
    # Format prices for Cadence array - handle scientific notation
    def format_price(p):
        if p == 0:
            return "0.0"
        elif p < 0.0001:
            # Convert scientific notation to decimal format
            return f"{p:.8f}".rstrip('0').rstrip('.')
        else:
            return str(p)
    
    flow_price_str = ", ".join(format_price(p) for p in flow_prices)
    yield_price_str = ", ".join(format_price(p) for p in yield_prices)
    
    # Format descriptions for Cadence string array
    desc_str = ", ".join(f'"{d}"' for d in descriptions)
    
    test_content = f'''import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"
import "Tidal"
import "TidalYieldStrategies"
import "TidalYieldAutoBalancers"
import "YieldToken"
import "DFB"

import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) fun setup() {{
    deployContracts()
    
    // Setup initial prices and liquidity
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 1.0)
    
    let reserveAmount = 200_000.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)
    
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: Type<@FlowToken.Vault>().identifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
}}

access(all) fun testMixedPriceScenario() {{
    logSeparator(title: "MIXED SCENARIO: {scenario_name}")
    
    // Define mixed price scenarios
    let flowPrices: [UFix64] = [{flow_price_str}]
    let yieldPrices: [UFix64] = [{yield_price_str}]
    let descriptions: [String] = [{desc_str}]
    
    // Create users for both systems
    let borrowUser = Test.createAccount()
    let balancerUser = Test.createAccount()
    
    // Setup both users
    setupMoetVault(borrowUser, beFailed: false)
    setupMoetVault(balancerUser, beFailed: false)
    setupYieldVault(balancerUser, beFailed: false)
    
    transferFlowTokens(to: borrowUser, amount: 1_000.0)
    transferFlowTokens(to: balancerUser, amount: 1_000.0)
    
    // Create auto-borrow position
    log("Creating auto-borrow position with 1000 FLOW...")
    let borrowTx = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, /storage/flowTokenVault, true],
        borrowUser
    )
    Test.expect(borrowTx, Test.beSucceeded())
    
    // Create auto-balancer tide
    log("Creating auto-balancer Tide with 1000 FLOW...")
    let tideTx = _executeTransaction(
        "../transactions/tidal-yield/create_tide.cdc",
        [Type<@TidalYieldStrategies.TracerStrategy>().identifier, Type<@FlowToken.Vault>().identifier, 1_000.0],
        balancerUser
    )
    Test.expect(tideTx, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: balancerUser.address) ?? panic("No Tide IDs found")
    let tideID = tideIDs[0]
    let autoBalancerID = getAutoBalancerIDByTideID(tideID: tideID, beFailed: false)
    
    // Log initial states
    logSeparator(title: "Initial State")
    let initialBorrowHealth = getPositionHealth(pid: 0, beFailed: false)
    let initialBalancerBalance = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    
    log("Auto-Borrow Position Health: ".concat(initialBorrowHealth.toString()))
    log("Auto-Balancer YieldToken Balance: ".concat(initialBalancerBalance.toString()))
    
    var i = 0
    while i < flowPrices.length {{
        let flowPrice = flowPrices[i]
        let yieldPrice = yieldPrices[i]
        let description = descriptions[i]
        
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(description))
        
        // Update both prices
        setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: flowPrice, tokenName: "FLOW")
        setMockOraclePriceWithLog(signer: tidalYieldAccount, forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: yieldPrice, tokenName: "YieldToken")
        
        // Check states before rebalancing
        let borrowHealthBefore = getPositionHealth(pid: 0, beFailed: false)
        let balancerBalanceBefore = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        log("")
        log("BEFORE REBALANCING:")
        log("  Auto-Borrow Health: ".concat(borrowHealthBefore.toString()))
        log("  Auto-Balancer Balance: ".concat(balancerBalanceBefore.toString()).concat(" YieldToken"))
        
        // Trigger both rebalances
        log("")
        log("Triggering simultaneous rebalances...")
        rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
        rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
        
        // Check states after rebalancing
        let borrowHealthAfter = getPositionHealth(pid: 0, beFailed: false)
        let balancerBalanceAfter = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        
        log("")
        log("AFTER REBALANCING:")
        log("  Auto-Borrow Health: ".concat(borrowHealthAfter.toString()))
        log("  Auto-Balancer Balance: ".concat(balancerBalanceAfter.toString()).concat(" YieldToken"))
        
        // Calculate changes
        var healthChange: UFix64 = 0.0
        var healthImproved = false
        if borrowHealthAfter > borrowHealthBefore {{
            healthChange = borrowHealthAfter - borrowHealthBefore
            healthImproved = true
        }} else if borrowHealthBefore > borrowHealthAfter {{
            healthChange = borrowHealthBefore - borrowHealthAfter
            healthImproved = false
        }}
        var balanceChange: UFix64 = 0.0
        var balanceIncreased = false
        if balancerBalanceAfter > balancerBalanceBefore {{
            balanceChange = balancerBalanceAfter - balancerBalanceBefore
            balanceIncreased = true
        }} else if balancerBalanceBefore > balancerBalanceAfter {{
            balanceChange = balancerBalanceBefore - balancerBalanceAfter
            balanceIncreased = false
        }}
        
        log("")
        log("CHANGES:")
        if healthChange > 0.0 {{
            log("  Health ".concat(healthImproved ? "IMPROVED" : "DETERIORATED").concat(" by: ".concat(healthChange.toString())))
        }} else {{
            log("  Health UNCHANGED")
        }}
        if balanceChange > 0.0 {{
            if balanceIncreased {{
                log("  Balance INCREASED by: ".concat(balanceChange.toString()))
            }} else {{
                log("  Balance DECREASED by: ".concat(balanceChange.toString()))
            }}
        }} else {{
            log("  Balance UNCHANGED")
        }}
        
        i = i + 1
    }}
    
    logSeparator(title: "Final State Summary")
    log("Auto-Borrow Final Health: ".concat(getPositionHealth(pid: 0, beFailed: false).toString()))
    log("Auto-Balancer Final Balance: ".concat(getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false).toString()))
    log("")
    log("Initial vs Final:")
    log("  Borrow Health: ".concat(initialBorrowHealth.toString()).concat(" -> ").concat(getPositionHealth(pid: 0, beFailed: false).toString()))
    log("  Balancer Balance: ".concat(initialBalancerBalance.toString()).concat(" -> ").concat(getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false).toString()))
}}
'''
    
    return test_content

def run_test(test_file):
    """Run the generated test file"""
    cmd = ["flow", "test", "--cover", test_file]
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    
    return result.returncode

def main():
    parser = argparse.ArgumentParser(description='Run mixed price scenarios for Tidal Protocol')
    parser.add_argument('--flow-prices', type=str,
                        help='Comma-separated FLOW price values (e.g., 1.0,0.5,2.0)')
    parser.add_argument('--yield-prices', type=str,
                        help='Comma-separated YieldToken price values (e.g., 1.0,1.2,0.8)')
    parser.add_argument('-d', '--descriptions', type=str,
                        help='Comma-separated descriptions for each stage')
    parser.add_argument('-n', '--name', type=str, default='Custom Mixed Scenario',
                        help='Scenario name')
    parser.add_argument('-s', '--scenario', choices=['default', 'inverse', 'decorrelated'],
                        help='Use a preset mixed scenario')
    
    args = parser.parse_args()
    
    # Preset mixed scenarios
    presets = {
        'default': {
            'flow_prices': [1.0, 0.5, 1.5, 0.3, 2.0, 1.0, 0.1, 1.0],
            'yield_prices': [1.0, 1.2, 0.8, 0.5, 2.0, 0.1, 1.0, 1.0],
            'descriptions': [
                "Baseline",
                "FLOW crash, YieldToken rise", 
                "FLOW rise, YieldToken drop",
                "Both crash",
                "Both moon",
                "FLOW stable, YieldToken crash",
                "FLOW crash, YieldToken stable",
                "Return to baseline"
            ],
            'name': 'Default Mixed Scenario'
        },
        'inverse': {
            'flow_prices': [1.0, 0.5, 2.0, 0.3, 1.5, 0.8],
            'yield_prices': [1.0, 2.0, 0.5, 3.0, 0.7, 1.2],
            'descriptions': [
                "Baseline",
                "Inverse correlation begins",
                "Inverse continues",
                "FLOW crashes, Yield moons",
                "Partial recovery",
                "Stabilization"
            ],
            'name': 'Inverse Correlation Scenario'
        },
        'decorrelated': {
            'flow_prices': [1.0, 1.1, 0.9, 1.2, 0.8, 1.0],
            'yield_prices': [1.0, 1.0, 1.5, 0.7, 2.0, 0.5],
            'descriptions': [
                "Baseline",
                "FLOW stable, Yield stable",
                "FLOW stable, Yield pumps",
                "FLOW rises, Yield crashes",
                "FLOW drops, Yield moons",
                "Return to baseline"
            ],
            'name': 'Decorrelated Price Movements'
        }
    }
    
    # Use preset or custom values
    if args.scenario:
        preset = presets[args.scenario]
        flow_prices = preset['flow_prices']
        yield_prices = preset['yield_prices']
        descriptions = preset['descriptions']
        scenario_name = preset['name']
    elif args.flow_prices and args.yield_prices:
        flow_prices = [float(p.strip()) for p in args.flow_prices.split(',')]
        yield_prices = [float(p.strip()) for p in args.yield_prices.split(',')]
        
        # Ensure both arrays are the same length
        if len(flow_prices) != len(yield_prices):
            print(f"Error: flow-prices ({len(flow_prices)}) and yield-prices ({len(yield_prices)}) must have the same number of values")
            sys.exit(1)
        
        if args.descriptions:
            descriptions = [d.strip() for d in args.descriptions.split(',')]
        else:
            descriptions = [f'FLOW: {flow_prices[i]}, Yield: {yield_prices[i]}' for i in range(len(flow_prices))]
        
        scenario_name = args.name
    else:
        print("Error: Either --scenario or both --flow-prices and --yield-prices must be specified")
        sys.exit(1)
    
    # Ensure descriptions match prices
    if len(descriptions) < len(flow_prices):
        descriptions.extend([f'Stage {i}' for i in range(len(descriptions), len(flow_prices))])
    
    # Generate test file
    test_content = generate_mixed_test_file(flow_prices, yield_prices, descriptions, scenario_name)
    
    # Write test file
    test_file = './cadence/tests/generated_mixed_test.cdc'
    with open(test_file, 'w') as f:
        f.write(test_content)
    
    print(f"Generated test file: {test_file}")
    print(f"Running mixed scenario test with {len(flow_prices)} price points...")
    print(f"Scenario: {scenario_name}")
    print(f"FLOW Prices: {flow_prices}")
    print(f"Yield Prices: {yield_prices}")
    print()
    
    # Run the test
    exit_code = run_test(test_file)
    
    # Clean up
    if os.path.exists(test_file):
        os.remove(test_file)
    
    sys.exit(exit_code)

if __name__ == '__main__':
    main() 