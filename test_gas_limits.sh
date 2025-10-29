#!/bin/bash
# Test deploying large EVM bytecode with various Cadence and EVM gas limits
# to determine the actual bottleneck

set -e

echo "=========================================="
echo "Gas Limit Testing for Large EVM Deployment"
echo "=========================================="
echo ""

# Get the large bytecode (MockMOET with constructor)
cd /Users/keshavgupta/tidal-sc
BYTECODE=$(./scripts/generate_evm_deploy_bytecode.sh MockMOET)
BYTECODE_LENGTH=${#BYTECODE}

echo "Bytecode length: $BYTECODE_LENGTH hex chars"
echo ""

# Test configurations
# Format: "CADENCE_GAS EVM_GAS DESCRIPTION"
TEST_CONFIGS=(
    "1000 15000000 baseline"
    "9999 15000000 high-cadence-low-evm"
    "1000 150000000 low-cadence-high-evm"
    "9999 150000000 both-high"
    "999999 15000000 very-high-cadence-low-evm"
    "999999 150000000 very-high-both"
)

# Create a temporary transaction file with parameterized gas
create_deploy_tx() {
    local evm_gas=$1
    cat > /tmp/deploy_test_tx.cdc <<EOF
import "EVM"

transaction(bytecodeHex: String) {
    prepare(signer: auth(Storage, SaveValue) &Account) {
        var coaRef = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
        if coaRef == nil {
            let coa <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-coa, to: /storage/evm)
            coaRef = signer.storage.borrow<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(from: /storage/evm)
        }
        
        let coa = coaRef!
        
        var code: [UInt8] = []
        var i = 0
        var hex = bytecodeHex
        if hex.slice(from: 0, upTo: 2) == "0x" {
            hex = hex.slice(from: 2, upTo: hex.length)
        }
        
        while i < hex.length {
            if i + 2 <= hex.length {
                let byteStr = "0x".concat(hex.slice(from: i, upTo: i + 2))
                if let byte = UInt8.fromString(byteStr) {
                    code.append(byte)
                }
            }
            i = i + 2
        }
        
        let deployResult = coa.deploy(
            code: code,
            gasLimit: $evm_gas,
            value: EVM.Balance(attoflow: 0)
        )
        
        log("✅ Deployed successfully")
        log("   Gas used: ".concat(deployResult.gasUsed.toString()))
    }
}
EOF
}

echo "Running tests..."
echo ""

for config in "${TEST_CONFIGS[@]}"; do
    read -r cadence_gas evm_gas desc <<< "$config"
    
    echo "----------------------------------------"
    echo "Test: $desc"
    echo "  Cadence --gas-limit: $cadence_gas"
    echo "  EVM gasLimit: $evm_gas"
    echo "----------------------------------------"
    
    # Create transaction with this EVM gas limit
    create_deploy_tx "$evm_gas"
    
    # Try to send with this Cadence gas limit
    if timeout 10 flow transactions send /tmp/deploy_test_tx.cdc \
        --network emulator \
        --signer emulator-account \
        --gas-limit "$cadence_gas" \
        --args-json "[{\"type\":\"String\",\"value\":\"$BYTECODE\"}]" \
        2>&1 | tee /tmp/test_output.log; then
        
        echo "✅ SUCCESS with cadence=$cadence_gas evm=$evm_gas"
        echo ""
        
    else
        echo "❌ FAILED with cadence=$cadence_gas evm=$evm_gas"
        
        # Check what error we got
        if grep -q "insufficient computation" /tmp/test_output.log; then
            echo "   Error: CADENCE COMPUTATION LIMIT"
        elif grep -q "out of gas" /tmp/test_output.log; then
            echo "   Error: EVM GAS LIMIT"
        elif grep -q "timeout" /tmp/test_output.log; then
            echo "   Error: TIMEOUT (>10s)"
        else
            echo "   Error: OTHER"
            tail -n 3 /tmp/test_output.log
        fi
        echo ""
    fi
done

echo "=========================================="
echo "Test Complete"
echo "=========================================="

# Cleanup
rm -f /tmp/deploy_test_tx.cdc /tmp/test_output.log

