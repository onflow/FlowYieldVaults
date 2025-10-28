# EVM Integration Discovery: Built-in vs Gateway

**Date**: October 27, 2025  
**Flow CLI Version**: v2.8.0 (v2.9.0 available)  
**Finding**: EVM is built-in to emulator!

---

## 🎯 User's Insight Was Correct!

**User said**: "Flow CLI already has EVM embedded"

**Evidence**:
```bash
flow emulator --help | grep evm
--setup-evm    enable EVM setup for the emulator, this will deploy the EVM contracts (default true)
```

**This is TRUE!** Flow CLI v2.8.0+ has built-in EVM support.

---

## 🔍 How EVM Works in Flow

### Built-in EVM Contract

**Deployed by Default**:
```
EVM contract: f8d6e0586b0a20c7 (service account)
```

**Accessible from Cadence**:
```cadence
import "EVM"

// Create a Cadence-Owned Account (COA)
let coa <- EVM.createCadenceOwnedAccount()
signer.storage.save(<-coa, to: /storage/evm)

// Call EVM contracts
let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
let result = coa.call(to: evmAddress, data: encodedData, gasLimit: 300000, value: 0)
```

### Two Ways to Use EVM

**Option 1: Direct Cadence Interaction** (Built-in)
- ✅ No separate gateway needed
- ✅ Interact via Cadence transactions/scripts
- ✅ Use `EVM.deploy()`, `EVM.call()`, etc.
- ❌ NO Ethereum JSON-RPC (no web3.js, cast, etc.)

**Option 2: EVM Gateway** (Separate service)
- ✅ Provides Ethereum JSON-RPC at localhost:8545
- ✅ Can use `cast`, `forge`, web3.js
- ✅ Translates eth_* calls to Cadence
- ❌ Needs COA account created first
- ❌ Extra process to run

---

## 💡 For PunchSwap V3 Deployment

### Approach A: Use Cadence Directly (Recommended)

**Deploy Solidity via Cadence**:
```cadence
import "EVM"

transaction(bytecode: String) {
    prepare(signer: auth(Storage) &Account) {
        // Get or create COA
        var coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
        if coa == nil {
            let newCoa <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-newCoa, to: /storage/evm)
            coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
        }
        
        // Deploy contract
        let contractBytecode = bytecode.decodeHex()
        let deployResult = coa!.deploy(
            code: contractBytecode,
            gasLimit: 15000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        log("Contract deployed at: ".concat(deployResult.deployedAddress.toString()))
    }
}
```

**Pros**:
- ✅ Works with built-in EVM
- ✅ No extra processes needed
- ✅ Can deploy PunchSwap V3!

**Cons**:
- Need to handle bytecode encoding
- Need to build contracts first with forge

### Approach B: Use EVM Gateway (More Tooling)

**Requires**:
1. Create COA account (`e03daebed8ca0615`)
2. Start EVM gateway process
3. Use standard Ethereum tools (cast, forge)

**Pros**:
- ✅ Use familiar Ethereum tooling
- ✅ Existing deployment scripts work

**Cons**:
- ❌ Extra setup (account creation, gateway process)
- ❌ More moving parts

---

## 🚀 Quick Path to PunchSwap V3

### Using Built-in EVM (No Gateway Needed!)

**Step 1: Compile PunchSwap Contracts**
```bash
cd /Users/keshavgupta/tidal-sc/solidity/lib/punch-swap-v3-contracts
forge build
```

**Step 2: Get Bytecode**
```bash
# Factory bytecode
cat out/PunchSwapV3Factory.sol/PunchSwapV3Factory.json | jq -r '.bytecode.object'

# Pool bytecode (created by factory)
cat out/PunchSwapV3Pool.sol/PunchSwapV3Pool.json | jq -r '.bytecode.object'
```

**Step 3: Deploy via Cadence**
```cadence
// cadence/transactions/evm/deploy_contract.cdc
import "EVM"

transaction(bytecode: String, constructorArgs: [UInt8]) {
    prepare(signer: auth(Storage, SaveValue) &Account) {
        // Get or create COA
        if signer.storage.type(at: /storage/evm) == nil {
            let coa <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-coa, to: /storage/evm)
        }
        
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)!
        
        // Decode and deploy
        var code: [UInt8] = []
        var i = 0
        while i < bytecode.length {
            let byte = UInt8.fromString(bytecode.slice(from: i, upTo: i+2), radix: 16) ?? 0
            code.append(byte)
            i = i + 2
        }
        
        // Append constructor args if any
        code = code.concat(constructorArgs)
        
        let deployResult = coa.deploy(
            code: code,
            gasLimit: 15000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        log("✅ Contract deployed at: ".concat(deployResult.deployedAddress.toString()))
    }
}
```

**Step 4: Call Contracts via Cadence**
```cadence
// Create pool
import "EVM"

transaction(factoryAddress: String, token0: String, token1: String, fee: UInt24) {
    prepare(signer: auth(Storage) &Account) {
        let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)!
        
        // Encode createPool(address,address,uint24)
        let data = EVM.encodeABIWithSignature(
            "createPool(address,address,uint24)",
            [token0, token1, fee]
        )
        
        let factory = EVM.EVMAddress.fromString(factoryAddress)
        let result = coa.call(
            to: factory,
            data: data,
            gasLimit: 5000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        // Decode pool address from result
        log("Pool created!")
    }
}
```

---

## 🎯 Recommendation: Use Built-in EVM!

**Why**:
1. ✅ Already running (emulator has it)
2. ✅ No extra processes needed
3. ✅ Can deploy Solidity contracts
4. ✅ Can call PunchSwap V3 functions
5. ✅ Simpler setup

**How**:
1. Compile PunchSwap contracts with forge
2. Deploy via Cadence using `EVM.deploy()`
3. Interact via Cadence using `EVM.call()`
4. Query state via Cadence scripts

**Effort**: 2-3 hours (vs 1 hour for gateway setup)

**Value**: Same result (real V3), but integrated with testing framework!

---

## 📋 Next Steps

### Immediate:
1. Compile PunchSwap V3 contracts
2. Create helper Cadence transaction to deploy Solidity
3. Deploy Factory, then Pool
4. Test one swap to show price impact

### Then:
- Integrate with mirror tests
- Replace MockV3 calls with EVM calls
- Get real V3 validation!

---

## Summary

**User was right**: EVM is built into Flow CLI (v2.8.0+)  
**Separate gateway**: NOT needed for basic EVM interaction  
**Gateway is useful for**: Ethereum tooling compatibility (cast, web3.js)  
**For our use case**: Built-in EVM is sufficient and simpler!

**Ready to proceed with built-in EVM approach?**

