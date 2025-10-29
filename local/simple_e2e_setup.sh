#!/bin/bash

echo "=== Simple E2E Setup for Swap Testing ==="

set -a
source ./local/punchswap/punchswap.env
set +a

echo ""
echo "Step 1: Deploying simple USDC token"
echo "======================================="

# Deploy a simple ERC20 for testing
DEPLOY_OUT=$(forge script ./solidity/script/02_DeployUSDC_WBTC_Create2.s.sol:DeployUSDC_WBTC_Create2 \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow 2>&1)

echo "$DEPLOY_OUT"

# Extract USDC address
USDC_ADDR=$(echo "$DEPLOY_OUT" | grep -oE "Deployed USDC at 0x[a-fA-F0-9]{40}" | grep -oE "0x[a-fA-F0-9]{40}" | head -1)

if [ -z "$USDC_ADDR" ]; then
    USDC_ADDR=$(echo "$DEPLOY_OUT" | grep -oE "USDC.*0x[a-fA-F0-9]{40}" | grep -oE "0x[a-fA-F0-9]{40}" | head -1)
fi

if [ -z "$USDC_ADDR" ]; then
    echo "Could not extract USDC address, using fallback from env"
    USDC_ADDR="0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95"
fi

echo ""
echo "USDC Address: $USDC_ADDR"
echo ""

# Save for bridge setup
cat > ./local/deployed_addresses.env << EOF
USDC_ADDR=$USDC_ADDR
WBTC_ADDR=0xeA6005B036A53Dd8Ceb8919183Fc7ac9E7bDC86E
EOF

echo "Step 2: Setting up PunchSwap contracts"
echo "======================================="
./local/punchswap/setup_punchswap.sh

echo ""
echo "Step 3: Bridging tokens"
echo "======================================="

# Bridge MOET to EVM
echo "Bridging MOET to EVM..."
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc \
  "A.045a1763c93006ca.MOET.Vault" \
  --signer emulator-account --gas-limit 9999 --signer tidal 2>&1 | grep -E "(Transaction ID|Status|Error)" || true

# Get MOET EVM address
MOET_EVM=$(flow scripts execute /tmp/get_moet_evm_addr.cdc --format inline 2>&1 | sed 's/"//g' || echo "")

if [ -n "$MOET_EVM" ]; then
    echo "MOET EVM Address: 0x$MOET_EVM"
fi

# Bridge USDC to Cadence  
echo ""
echo "Bridging USDC to Cadence..."
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc \
  $USDC_ADDR \
  --signer emulator-account --gas-limit 9999 --signer tidal 2>&1 | grep -E "(Transaction ID|Status|Error)" || true

# Setup USDC vault for tidal account
USDC_STORAGE_PATH="/storage/EVMVMBridgedToken_$(echo $USDC_ADDR | sed 's/0x//' | tr '[:upper:]' '[:lower:]')Vault"

echo ""
echo "Setting up USDC vault at: $USDC_STORAGE_PATH"

# Create a transaction to setup the vault
cat > /tmp/setup_usdc_vault.cdc << 'ENDTX'
import "FungibleToken"
import "FlowEVMBridgeConfig"
import "EVM"

transaction(evmAddressHex: String) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let evmAddr = EVM.addressFromString(evmAddressHex)
        let vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: evmAddr)
            ?? panic("No vault type associated with ".concat(evmAddressHex))
        
        let pathIdentifier = "EVMVMBridgedToken_".concat(
            evmAddressHex.slice(from: 2, upTo: evmAddressHex.length).toLower()
        ).concat("Vault")
        
        let storagePath = StoragePath(identifier: pathIdentifier)!
        let publicPath = PublicPath(identifier: pathIdentifier.concat("_balance"))!
        
        // Check if vault already exists
        if signer.storage.type(at: storagePath) == nil {
            // Create and save vault
            let vault <- FlowEVMBridgeConfig.createEmptyVault(type: vaultType)
            signer.storage.save(<-vault, to: storagePath)
            
            // Create public capability
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(storagePath)
            signer.capabilities.publish(cap, at: publicPath)
            
            log("Created vault at ".concat(storagePath.toString()))
        } else {
            log("Vault already exists at ".concat(storagePath.toString()))
        }
    }
}
ENDTX

flow transactions send /tmp/setup_usdc_vault.cdc $USDC_ADDR --signer tidal --gas-limit 9999 2>&1 | grep -E "(Transaction ID|Status|Error|Created|exists)" || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "You can now test the swap with:"
echo "  flow transactions send ./cadence/transactions/connectors/univ3-swap-connector.cdc --signer tidal --gas-limit 9999"
echo ""

