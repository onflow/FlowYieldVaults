#!/bin/bash
# Run Cadence tests and capture outputs for fuzzy testing

echo "Running Cadence tests for fuzzy testing..."

# Create output directory
mkdir -p test_outputs

# Run each test and capture output
for test_file in cadence/tests/generated/*.cdc; do
    if [[ "$test_file" != *"run_all_generated_tests.cdc" ]]; then
        test_name=$(basename "$test_file" .cdc)
        echo "Running $test_name..."
        
        # Run test and capture output
        flow test "$test_file" > "test_outputs/${test_name}_output.txt" 2>&1
        
        if [ $? -eq 0 ]; then
            echo "✓ $test_name passed"
        else
            echo "❌ $test_name failed"
        fi
    fi
done

echo "All tests completed. Outputs saved in test_outputs/"
