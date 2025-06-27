#!/usr/bin/env python3
"""
Tidal Protocol Price Scenario Test Runner
Generates and runs parameterized price tests for Cadence
"""

import argparse
import subprocess
import sys
import os
import json

def generate_test_file(test_type, prices, descriptions, scenario_name):
    """Generate a Cadence test file with custom price scenarios"""
    
    # Format prices for Cadence array - handle scientific notation
    def format_price(p):
        if p == 0:
            return "0.0"
        elif p < 0.0001:
            # Convert scientific notation to decimal format
            return f"{p:.8f}".rstrip('0').rstrip('.')
        else:
            return str(p)
    
    price_str = ", ".join(format_price(p) for p in prices)
    
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

access(all) let flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) let moetTokenIdentifier = Type<@MOET.Vault>().identifier
access(all) let yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all) struct PriceScenario {{
    access(all) let name: String
    access(all) let token: String
    access(all) let prices: [UFix64]
    access(all) let descriptions: [String]
    
    init(name: String, token: String, prices: [UFix64], descriptions: [String]) {{
        self.name = name
        self.token = token
        self.prices = prices
        self.descriptions = descriptions
    }}
}}

access(all) fun setup() {{
    deployContracts()
    
    // Setup initial prices and liquidity
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)
    
    let reserveAmount = 100_000.0
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
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
}}

access(all)
fun testCustomPriceScenario() {{
    let prices: [UFix64] = [{price_str}]
    let descriptions: [String] = [{desc_str}]
    
'''
    
    if test_type in ["auto-borrow", "all"]:
        test_content += f'''
    // Auto-borrow test
    let borrowScenario = PriceScenario(
        name: "{scenario_name} - Auto-Borrow",
        token: "FLOW",
        prices: prices,
        descriptions: descriptions
    )
    
    logSeparator(title: "AUTO-BORROW SCENARIO: ".concat(borrowScenario.name))
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0, tokenName: "FLOW")
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0, tokenName: "MOET")
    
    log("Creating position with 1000 FLOW...")
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(txRes, Test.beSucceeded())
    
    let initialHealth = getPositionHealth(pid: 0, beFailed: false)
    log("Initial position health: ".concat(initialHealth.toString()))
    
    var i = 0
    for price in borrowScenario.prices {{
        logSeparator(title: "Stage ".concat(i.toString()).concat(": ").concat(borrowScenario.descriptions[i]))
        
        setMockOraclePriceWithLog(
            signer: protocolAccount, 
            forTokenIdentifier: flowTokenIdentifier, 
            price: price, 
            tokenName: borrowScenario.token
        )
        
        let healthBefore = getPositionHealth(pid: 0, beFailed: false)
        log("Health before rebalance: ".concat(healthBefore.toString()))
        
        log("Triggering rebalance...")
        rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
        
        let healthAfter = getPositionHealth(pid: 0, beFailed: false)
        log("Health after rebalance: ".concat(healthAfter.toString()))
        
        logPositionDetails(pid: 0, stage: "After price = ".concat(price.toString()))
        
        i = i + 1
    }}
'''
    
    if test_type in ["auto-balancer", "all"]:
        test_content += f'''
    
    // Auto-balancer test  
    let balancerScenario = PriceScenario(
        name: "{scenario_name} - Auto-Balancer",
        token: "YieldToken",
        prices: prices,
        descriptions: descriptions
    )
    
    logSeparator(title: "AUTO-BALANCER SCENARIO: ".concat(balancerScenario.name))
    
    addStrategyComposer(
        signer: tidalYieldAccount,
        strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier,
        composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
        beFailed: false
    )
    
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    setupYieldVault(user2, beFailed: false)
    transferFlowTokens(to: user2, amount: 1_000.0)
    
    log("Creating Tide with TracerStrategy...")
    let createTideRes = _executeTransaction(
        "../transactions/tidal-yield/create_tide.cdc",
        [Type<@TidalYieldStrategies.TracerStrategy>().identifier, flowTokenIdentifier, 1_000.0],
        user2
    )
    Test.expect(createTideRes, Test.beSucceeded())
    
    let tideIDs = getTideIDs(address: user2.address) ?? panic("No Tide IDs found")
    let tideID = tideIDs[0]
    let autoBalancerID = getAutoBalancerIDByTideID(tideID: tideID, beFailed: false)
    
    let initialBalance = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
    log("Initial AutoBalancer balance: ".concat(initialBalance.toString()).concat(" YieldToken"))
    
    var j = 0
    for price in balancerScenario.prices {{
        logSeparator(title: "Stage ".concat(j.toString()).concat(": ").concat(balancerScenario.descriptions[j]))
        
        setMockOraclePriceWithLog(
            signer: tidalYieldAccount, 
            forTokenIdentifier: yieldTokenIdentifier, 
            price: price, 
            tokenName: balancerScenario.token
        )
        
        logAutoBalancerState(id: autoBalancerID, yieldPrice: price, stage: "Before Rebalance")
        
        log("Triggering rebalance...")
        rebalanceTide(signer: tidalYieldAccount, id: tideID, force: true, beFailed: false)
        
        let balanceAfter = getAutoBalancerBalanceByID(id: autoBalancerID, beFailed: false)
        logAutoBalancerState(id: autoBalancerID, yieldPrice: price, stage: "After Rebalance")
        
        if balanceAfter != initialBalance {{
            let change = safeSubtract(a: balanceAfter, b: initialBalance, context: "balance change")
            if balanceAfter > initialBalance {{
                log("Balance INCREASED by: ".concat(change.toString()))
            }} else {{
                log("Balance DECREASED by: ".concat(safeSubtract(a: initialBalance, b: balanceAfter, context: "balance decrease").toString()))
            }}
        }} else {{
            log("Balance UNCHANGED")
        }}
        
        j = j + 1
    }}
'''
    
    test_content += "\n}"
    
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
    parser = argparse.ArgumentParser(description='Run parameterized price tests for Tidal Protocol')
    parser.add_argument('-t', '--type', choices=['auto-borrow', 'auto-balancer', 'all'], 
                        default='all', help='Test type to run')
    parser.add_argument('-p', '--prices', type=str, 
                        help='Comma-separated price values (e.g., 0.5,1.0,2.0)')
    parser.add_argument('-d', '--descriptions', type=str,
                        help='Comma-separated descriptions for each price')
    parser.add_argument('-n', '--name', type=str, default='Custom Scenario',
                        help='Scenario name')
    parser.add_argument('-s', '--scenario', choices=['extreme', 'gradual', 'volatile'],
                        help='Use a preset scenario')
    
    args = parser.parse_args()
    
    # Preset scenarios
    presets = {
        'extreme': {
            'prices': [0.5, 0.1, 2.0, 5.0, 0.25, 1.0],
            'descriptions': ['Drop 50%', 'Crash 90%', 'Recover to 2x', 'Moon to 5x', 'Crash to 0.25', 'Stabilize at 1.0'],
            'name': 'Extreme Price Volatility'
        },
        'gradual': {
            'prices': [1.1, 1.2, 1.3, 1.4, 1.5, 1.3, 1.1, 0.9, 0.7, 0.5],
            'descriptions': ['+10%', '+20%', '+30%', '+40%', '+50%', 'Drop to 1.3', 'Drop to 1.1', 'Drop to 0.9', 'Drop to 0.7', 'Drop to 0.5'],
            'name': 'Gradual Price Changes'
        },
        'volatile': {
            'prices': [1.5, 0.7, 1.8, 0.4, 1.2, 0.9, 2.5, 0.3, 1.0],
            'descriptions': ['Pump to 1.5', 'Dump to 0.7', 'Pump to 1.8', 'Crash to 0.4', 'Recover to 1.2', 'Drop to 0.9', 'Moon to 2.5', 'Crash to 0.3', 'Stabilize at 1.0'],
            'name': 'Volatile Price Swings'
        }
    }
    
    # Use preset or custom values
    if args.scenario:
        preset = presets[args.scenario]
        prices = preset['prices']
        descriptions = preset['descriptions']
        scenario_name = preset['name']
    elif args.prices:
        prices = [float(p.strip()) for p in args.prices.split(',')]
        if args.descriptions:
            descriptions = [d.strip() for d in args.descriptions.split(',')]
        else:
            descriptions = [f'Price: {p}' for p in prices]
        scenario_name = args.name
    else:
        print("Error: Either --prices or --scenario must be specified")
        sys.exit(1)
    
    # Ensure descriptions match prices
    if len(descriptions) < len(prices):
        descriptions.extend([f'Price: {prices[i]}' for i in range(len(descriptions), len(prices))])
    
    # Generate test file
    test_content = generate_test_file(args.type, prices, descriptions, scenario_name)
    
    # Write test file
    test_file = './cadence/tests/generated_price_test.cdc'
    with open(test_file, 'w') as f:
        f.write(test_content)
    
    print(f"Generated test file: {test_file}")
    print(f"Running {args.type} test with {len(prices)} price points...")
    print(f"Scenario: {scenario_name}")
    print(f"Prices: {prices}")
    print()
    
    # Run the test
    exit_code = run_test(test_file)
    
    # Clean up
    if os.path.exists(test_file):
        os.remove(test_file)
    
    sys.exit(exit_code)

if __name__ == '__main__':
    main() 