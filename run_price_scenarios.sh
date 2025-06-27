#!/bin/bash

# Tidal Protocol Price Scenario Test Runner
# Usage: ./run_price_scenarios.sh [options]

set -e

# Default values
TEST_TYPE="all"
PRICES=""
DESCRIPTIONS=""
SCENARIO_NAME="Custom Scenario"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Display help
show_help() {
    echo "Tidal Protocol Price Scenario Test Runner"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -t, --type TYPE          Test type: auto-borrow, auto-balancer, or all (default: all)"
    echo "  -p, --prices PRICES      Comma-separated price values (e.g., 0.5,1.0,2.0)"
    echo "  -d, --descriptions DESC  Comma-separated descriptions for each price"
    echo "  -n, --name NAME          Scenario name (default: 'Custom Scenario')"
    echo "  -s, --scenario PRESET    Use preset scenario: extreme, gradual, volatile"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Run extreme volatility test"
    echo "  $0 --scenario extreme"
    echo ""
    echo "  # Custom auto-borrow test with specific prices"
    echo "  $0 --type auto-borrow --prices 0.5,0.8,1.2,2.0 --descriptions 'Drop 50%,Drop 20%,Rise 20%,Double'"
    echo ""
    echo "  # Run all preset scenarios"
    echo "  $0 --scenario all"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            TEST_TYPE="$2"
            shift 2
            ;;
        -p|--prices)
            PRICES="$2"
            shift 2
            ;;
        -d|--descriptions)
            DESCRIPTIONS="$2"
            shift 2
            ;;
        -n|--name)
            SCENARIO_NAME="$2"
            shift 2
            ;;
        -s|--scenario)
            SCENARIO="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Function to run a specific test
run_test() {
    local test_name=$1
    echo -e "${YELLOW}Running test: $test_name${NC}"
    flow test --cover "./cadence/tests/price_scenario_test.cdc" | cat
}

# Handle preset scenarios
if [ ! -z "$SCENARIO" ]; then
    case $SCENARIO in
        extreme)
            echo -e "${GREEN}Running extreme price volatility scenario...${NC}"
            run_test "testExtremePriceMovements"
            ;;
        gradual)
            echo -e "${GREEN}Running gradual price changes scenario...${NC}"
            run_test "testGradualPriceChanges"
            ;;
        volatile)
            echo -e "${GREEN}Running volatile price swings scenario...${NC}"
            run_test "testVolatilePriceSwings"
            ;;
        all)
            echo -e "${GREEN}Running all preset scenarios...${NC}"
            run_test "testExtremePriceMovements"
            run_test "testGradualPriceChanges"
            run_test "testVolatilePriceSwings"
            ;;
        *)
            echo -e "${RED}Unknown scenario: $SCENARIO${NC}"
            exit 1
            ;;
    esac
    exit 0
fi

# If custom prices are provided, create a custom test
if [ ! -z "$PRICES" ]; then
    # Create a temporary test file with custom scenario
    cat > ./cadence/tests/custom_price_test.cdc << EOF
import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"
import "Tidal"
import "TidalYieldStrategies"
import "TidalYieldAutoBalancers"
import "YieldToken"
import "DFB"

import "./test_helpers.cdc"

// Include price scenario helpers directly
access(all) struct PriceScenario {
    access(all) let name: String
    access(all) let token: String
    access(all) let prices: [UFix64]
    access(all) let descriptions: [String]
    
    init(name: String, token: String, prices: [UFix64], descriptions: [String]) {
        self.name = name
        self.token = token
        self.prices = prices
        self.descriptions = descriptions
    }
}

access(all) fun setup() {
    deployContracts()
    
    // Setup initial prices
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000008), forTokenIdentifier: Type<@YieldToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000008), forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0)
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000008), forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 1.0)
}

access(all) fun testCustomPriceScenario() {
    let prices: [UFix64] = [$PRICES]
    var descriptions: [String] = []
    
    // Handle descriptions if provided
    $(if [ ! -z "$DESCRIPTIONS" ]; then
        echo "descriptions = [$(echo "$DESCRIPTIONS" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
    else
        echo "// No descriptions provided, will use defaults"
    fi)
    
    let customScenario = PriceScenario(
        name: "$SCENARIO_NAME",
        token: "FLOW",
        prices: prices,
        descriptions: descriptions.length > 0 ? descriptions : prices.map(fun(p: UFix64): String { return "Price: ".concat(p.toString()) })
    )
    
    if "$TEST_TYPE" == "auto-borrow" || "$TEST_TYPE" == "all" {
        runAutoBorrowPriceScenario(scenario: customScenario)
    }
    
    if "$TEST_TYPE" == "auto-balancer" || "$TEST_TYPE" == "all" {
        // Change token to YieldToken for auto-balancer tests
        let yieldScenario = PriceScenario(
            name: "$SCENARIO_NAME",
            token: "YieldToken", 
            prices: prices,
            descriptions: descriptions.length > 0 ? descriptions : prices.map(fun(p: UFix64): String { return "Price: ".concat(p.toString()) })
        )
        runAutoBalancerPriceScenario(
            scenario: yieldScenario,
            strategyIdentifier: Type<@TidalYieldStrategies.TracerStrategy>().identifier
        )
    }
}
EOF

    echo -e "${GREEN}Running custom price scenario...${NC}"
    echo -e "Prices: $PRICES"
    echo -e "Type: $TEST_TYPE"
    
    flow test --cover "./cadence/tests/custom_price_test.cdc" | cat
    
    # Clean up
    rm -f ./cadence/tests/custom_price_test.cdc
else
    # Run default tests
    echo -e "${GREEN}Running default price scenario tests...${NC}"
    flow test --cover "./cadence/tests/price_scenario_test.cdc" | cat
fi 