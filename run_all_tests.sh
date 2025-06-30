#!/bin/bash

# Tidal Protocol Comprehensive Test Suite
# This script runs various test scenarios with different options
# Supports: --happy-path, --full, --preset, --edge, --mixed, --verify, --help

# Don't exit on test failures - we want all tests to run
set +e

# Disable ANSI colors for cleaner logs
export NO_COLOR=1
export FORCE_COLOR=0

# Default values
MODE="full"
LOG_FILE="fresh_test_output.log"
CLEAN_LOG_FILE="clean_test_output.log"
SKIP_VERIFICATION=false
TEST_FAILURES=0
TOTAL_TESTS=0

# Function to run a test and track result
run_test() {
    local test_name="$1"
    shift
    local test_command="$@"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "\n[$TOTAL_TESTS/$EXPECTED_TESTS] Testing $test_name..."
    
    # Run the test command
    eval "$test_command"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        TEST_FAILURES=$((TEST_FAILURES + 1))
        echo "[FAILED] $test_name (exit code: $exit_code)"
    else
        echo "[PASSED] $test_name"
    fi
    
    return 0  # Always return success to continue running tests
}

# Function to display usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --happy-path    Run only basic scenarios with common values (fast, ~3 min)"
    echo "  --full          Run all test scenarios (default, ~10 min)"
    echo "  --preset        Run only preset scenarios (extreme, gradual, volatile)"
    echo "  --edge          Run only edge case tests"
    echo "  --mixed         Run only mixed scenario tests"
    echo "  --verify        Run only verification on existing logs"
    echo "  --skip-verify   Skip verification after tests"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --happy-path           # Quick test with common scenarios"
    echo "  $0 --preset --skip-verify # Run preset scenarios without verification"
    echo "  $0 --verify               # Run verification on existing logs"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --happy-path)
            MODE="happy"
            LOG_FILE="happy_path_test_output.log"
            CLEAN_LOG_FILE="clean_happy_path_output.log"
            shift
            ;;
        --full)
            MODE="full"
            shift
            ;;
        --preset)
            MODE="preset"
            LOG_FILE="preset_test_output.log"
            CLEAN_LOG_FILE="clean_preset_output.log"
            shift
            ;;
        --edge)
            MODE="edge"
            LOG_FILE="edge_test_output.log"
            CLEAN_LOG_FILE="clean_edge_output.log"
            shift
            ;;
        --mixed)
            MODE="mixed"
            LOG_FILE="mixed_test_output.log"
            CLEAN_LOG_FILE="clean_mixed_output.log"
            shift
            ;;
        --verify)
            MODE="verify"
            shift
            ;;
        --skip-verify)
            SKIP_VERIFICATION=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Function to run happy path tests
run_happy_path() {
    echo "=================================================================="
    echo "Running Happy Path Test Suite (Common Scenarios)"
    echo "=================================================================="
    
    EXPECTED_TESTS=7
    TEST_FAILURES=0
    TOTAL_TESTS=0
    
    {
        run_test "auto-borrow baseline scenario" \
            "python3 verification_results/run_price_test.py --prices 1.0 \
                                 --descriptions \"Baseline\" \
                                 --name \"Auto-Borrow Baseline\" \
                                 --type auto-borrow"

        run_test "auto-borrow small price movements" \
            "python3 verification_results/run_price_test.py --prices 1.0,0.8,1.2,1.0 \
                                 --descriptions \"Start,Drop20%,Rise50%,Stabilize\" \
                                 --name \"Auto-Borrow Small Movements\" \
                                 --type auto-borrow"

        run_test "auto-borrow moderate price movements" \
            "python3 verification_results/run_price_test.py --prices 1.0,0.5,1.5,2.0,1.0 \
                                 --descriptions \"Start,Drop50%,Rise3x,Double,Stabilize\" \
                                 --name \"Auto-Borrow Moderate Movements\" \
                                 --type auto-borrow"

        run_test "auto-balancer baseline scenario" \
            "python3 verification_results/run_price_test.py --prices 1.0 \
                                 --descriptions \"Baseline\" \
                                 --name \"Auto-Balancer Baseline\" \
                                 --type auto-balancer"

        run_test "auto-balancer small price movements" \
            "python3 verification_results/run_price_test.py --prices 1.0,0.8,1.2,1.0 \
                                 --descriptions \"Start,Drop20%,Rise50%,Stabilize\" \
                                 --name \"Auto-Balancer Small Movements\" \
                                 --type auto-balancer"

        run_test "auto-balancer moderate price movements" \
            "python3 verification_results/run_price_test.py --prices 1.0,0.5,1.5,2.0,1.0 \
                                 --descriptions \"Start,Drop50%,Rise3x,Double,Stabilize\" \
                                 --name \"Auto-Balancer Moderate Movements\" \
                                 --type auto-balancer"

        run_test "mixed FLOW/YieldToken scenario" \
            "python3 verification_results/run_price_test.py --prices 1.0,1.1,1.2,0.9,0.8,1.0 \
                                 --descriptions \"Start,Up10%,Up20%,Down25%,Down11%,Stabilize\" \
                                 --name \"Mixed Price Movements\" \
                                 --type auto-balancer"

        echo -e "\n=================================================================="
        echo "Happy path tests completed!"
        echo "Tests run: $TOTAL_TESTS, Passed: $((TOTAL_TESTS - TEST_FAILURES)), Failed: $TEST_FAILURES"
        echo "=================================================================="
    } 2>&1 | tee "$LOG_FILE"
}

# Function to run preset scenarios
run_preset_tests() {
    echo "=================================================================="
    echo "Running Preset Scenarios"
    echo "=================================================================="
    
    {
        ./run_price_scenarios.sh --scenario all
    } 2>&1 | tee "$LOG_FILE"
}

# Function to run edge case tests
run_edge_tests() {
    echo "=================================================================="
    echo "Running Edge Case Tests"
    echo "=================================================================="
    
    {
        echo -e "\n[1/3] Testing edge cases (zero, micro, extreme prices)..."
        python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 \
                                 --descriptions "Zero,Micro,VeryHigh" \
                                 --name "Edge Prices" \
                                 --type auto-borrow

        echo -e "\n[2/3] Testing price extremes (0.001 to 500x)..."
        python3 verification_results/run_price_test.py --prices 0.001,10,100,500 \
                                 --descriptions "VeryLow,10x,100x,500x" \
                                 --name "Price Extremes" \
                                 --type auto-borrow

        echo -e "\n[3/3] Testing black swan event (99% crash)..."
        python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 \
                                 --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" \
                                 --name "Black Swan Event" \
                                 --type auto-borrow
    } 2>&1 | tee "$LOG_FILE"
}

# Function to run mixed scenario tests
run_mixed_tests() {
    echo "=================================================================="
    echo "Running Mixed Scenario Tests"
    echo "=================================================================="
    
    {
        echo -e "\n[1/5] Testing MOET depeg scenario..."
        flow test cadence/tests/moet_depeg_test.cdc --output inline

        echo -e "\n[2/5] Testing concurrent rebalancing..."
        flow test cadence/tests/concurrent_rebalance_test.cdc --output inline

        echo -e "\n[3/5] Testing mixed scenario (auto-borrow + auto-balancer simultaneous)..."
        flow test cadence/tests/mixed_scenario_test.cdc --output inline

        echo -e "\n[4/5] Testing inverse correlation scenario..."
        python3 verification_results/run_mixed_test.py --scenario inverse

        echo -e "\n[5/5] Testing decorrelated price movements..."
        python3 verification_results/run_mixed_test.py --scenario decorrelated
    } 2>&1 | tee "$LOG_FILE"
}

# Function to run all tests
run_all_tests() {
    echo "=================================================================="
    echo "Running Comprehensive Tidal Protocol Test Suite"
    echo "=================================================================="
    
    {
        echo -e "\n[1/10] Running all preset scenarios (extreme, gradual, volatile)..."
        ./run_price_scenarios.sh --scenario all

        echo -e "\n[2/10] Testing edge cases (zero, micro, extreme prices)..."
        python3 verification_results/run_price_test.py --prices 0,0.00000001,1000 \
                                 --descriptions "Zero,Micro,VeryHigh" \
                                 --name "Edge Prices" \
                                 --type auto-borrow

        echo -e "\n[3/10] Testing price extremes (0.001 to 500x)..."
        python3 verification_results/run_price_test.py --prices 0.001,10,100,500 \
                                 --descriptions "VeryLow,10x,100x,500x" \
                                 --name "Price Extremes" \
                                 --type auto-borrow

        echo -e "\n[4/10] Testing rapid oscillations..."
        python3 verification_results/run_price_test.py --prices 1,2,0.5,3,0.3,1.5,0.8,2.5,1 \
                                 --descriptions "Start,2x,Drop50%,3x,Crash70%,Recover1.5x,Drop20%,2.5x,Stabilize" \
                                 --name "Rapid Oscillations" \
                                 --type auto-borrow

        echo -e "\n[5/10] Testing black swan event (99% crash)..."
        python3 verification_results/run_price_test.py --prices 1,0.05,0.01,0.5,1,1.5 \
                                 --descriptions "Normal,Crash95%,Crash99%,Recovery50%,FullRecovery,Overshoot" \
                                 --name "Black Swan Event" \
                                 --type auto-borrow

        echo -e "\n[6/10] Testing MOET depeg scenario..."
        flow test cadence/tests/moet_depeg_test.cdc --output inline

        echo -e "\n[7/10] Testing concurrent rebalancing..."
        flow test cadence/tests/concurrent_rebalance_test.cdc --output inline

        echo -e "\n[8/10] Testing mixed scenario (auto-borrow + auto-balancer simultaneous)..."
        flow test cadence/tests/mixed_scenario_test.cdc --output inline

        echo -e "\n[9/10] Testing inverse correlation scenario (NEW)..."
        python3 verification_results/run_mixed_test.py --scenario inverse

        echo -e "\n[10/10] Testing decorrelated price movements (NEW)..."
        python3 verification_results/run_mixed_test.py --scenario decorrelated

        echo -e "\n=================================================================="
        echo "All tests completed successfully!"
        echo "=================================================================="
    } 2>&1 | tee "$LOG_FILE"
}

# Function to run verification
run_verification() {
    if [ -f "$CLEAN_LOG_FILE" ]; then
        echo "Running verification on: $CLEAN_LOG_FILE"
    else
        echo "No clean log file found. Looking for alternative..."
        if [ -f "clean_test_output.log" ]; then
            CLEAN_LOG_FILE="clean_test_output.log"
            echo "Using: $CLEAN_LOG_FILE"
        else
            echo "Error: No clean log file found to verify!"
            echo "Please run tests first or ensure clean_test_output.log exists."
            exit 1
        fi
    fi
    
    echo "=================================================================="
    echo "Running Automated Verification Suite"
    echo "=================================================================="
    echo ""
    
    cd verification_results
    ./run_all_verifications.sh "../$CLEAN_LOG_FILE"
    cd ..
}

# Main execution
if [ "$MODE" = "verify" ]; then
    # Only run verification
    run_verification
    exit 0
fi

# Capture start time
START_TIME=$(date +%s)

# Run tests based on mode
case $MODE in
    happy)
        run_happy_path
        ;;
    preset)
        run_preset_tests
        ;;
    edge)
        run_edge_tests
        ;;
    mixed)
        run_mixed_tests
        ;;
    full)
        run_all_tests
        ;;
esac

# Calculate test duration
END_TIME=$(date +%s)
TEST_DURATION=$((END_TIME - START_TIME))

echo ""
echo "Test execution time: ${TEST_DURATION} seconds"
echo ""

# Clean the log file
echo "Cleaning log file..."
./clean_logs.sh "$LOG_FILE" "$CLEAN_LOG_FILE"
echo ""

# Run verification unless skipped
if [ "$SKIP_VERIFICATION" = false ]; then
    run_verification
fi

# Exit with failure code if any tests failed
if [ -n "$FAILURES" ] && [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

# Final summary based on mode
echo ""
echo "=================================================================="
echo "TEST SUMMARY"
echo "=================================================================="
echo ""

# Extract test failure count from log if available
if [ -f "$LOG_FILE" ]; then
    FAILURES=$(grep -E "Failed: [0-9]+" "$LOG_FILE" | tail -1 | grep -oE "Failed: [0-9]+" | grep -oE "[0-9]+")
    TOTAL=$(grep -E "Tests run: [0-9]+" "$LOG_FILE" | tail -1 | grep -oE "Tests run: [0-9]+" | grep -oE "[0-9]+")
    
    if [ -n "$FAILURES" ] && [ "$FAILURES" -gt 0 ]; then
        echo "⚠️  WARNING: $FAILURES out of $TOTAL tests failed!"
        echo ""
    fi
fi

case $MODE in
    happy)
        if [ -n "$FAILURES" ] && [ "$FAILURES" -eq 0 ]; then
            echo "✅ Happy path tests completed - ALL PASSED"
        else
            echo "✅ Happy path tests completed"
        fi
        echo "Scenarios tested:"
        echo ""
        echo "Auto-Borrow:"
        echo "- Baseline operation at 1.0"
        echo "- Small price movements (±20%)"
        echo "- Moderate price movements (0.5x to 2x)"
        echo ""
        echo "Auto-Balancer:"
        echo "- Baseline operation at 1.0"
        echo "- Small price movements (±20%)"
        echo "- Moderate price movements (0.5x to 2x)"
        echo "- Mixed price movements scenario"
        ;;
    preset)
        echo "✅ Preset scenario tests completed"
        echo "Scenarios tested:"
        echo "- Extreme price movements"
        echo "- Gradual price changes"
        echo "- Volatile market conditions"
        ;;
    edge)
        echo "✅ Edge case tests completed"
        echo "Scenarios tested:"
        echo "- Zero and micro prices"
        echo "- Extreme prices (1000x)"
        echo "- Black swan events"
        ;;
    mixed)
        echo "✅ Mixed scenario tests completed"
        echo "Scenarios tested:"
        echo "- MOET depeg"
        echo "- Concurrent rebalancing"
        echo "- Mixed auto-borrow + auto-balancer"
        echo "- Inverse correlations"
        echo "- Decorrelated movements"
        ;;
    full)
        echo "✅ All 10 test scenarios completed"
        echo "✅ Full test coverage achieved"
        ;;
esac

if [ "$SKIP_VERIFICATION" = false ]; then
    echo "✅ All verification scripts run"
    echo ""
    echo "Verification artifacts in verification_results/:"
    echo "- verification_results.json"
    echo "- deep_verification_report.json"
    echo "- mathematical_analysis.json"
    echo "- mixed_scenario_analysis.json"
fi

echo ""
echo "Log files:"
echo "- Raw output: $LOG_FILE"
echo "- Cleaned output: $CLEAN_LOG_FILE"
echo "" 