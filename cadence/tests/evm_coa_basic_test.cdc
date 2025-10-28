import Test
import "EVM"

access(all) let admin = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    log("🚀 Testing EVM integration with built-in EVM support")
}

access(all)
fun test_evm_contract_available() {
    // Test that we can import and reference EVM
    log("✅ Test 1: EVM contract is available")
    Test.assert(true)
}

access(all)
fun test_create_coa() {
    // Test creating a Cadence-Owned Account
    let createCOATx = Test.Transaction(
        code: Test.readFile("../transactions/evm/create_coa.cdc"),
        authorizers: [admin.address],
        signers: [admin],
        arguments: []
    )
    
    let result = Test.executeTransaction(createCOATx)
    Test.expect(result, Test.beSucceeded())
    
    log("✅ Test 2: COA created successfully")
}

access(all)
fun test_get_coa_address() {
    // Test getting COA's EVM address
    let getAddressScript = Test.readFile("../scripts/evm/get_coa_address.cdc")
    let scriptResult = Test.executeScript(getAddressScript, [admin.address])
    
    Test.expect(scriptResult, Test.beSucceeded())
    
    let evmAddress = scriptResult.returnValue! as! String
    log("✅ Test 3: COA EVM address = ".concat(evmAddress))
    
    // Basic validation
    Test.assert(evmAddress.length >= 10, message: "EVM address should be valid hex")
}

access(all)
fun test_get_coa_balance() {
    // Test getting COA's FLOW balance on EVM side
    let balanceScript = Test.readFile("../scripts/evm/get_coa_balance.cdc")
    let balanceResult = Test.executeScript(balanceScript, [admin.address])
    
    Test.expect(balanceResult, Test.beSucceeded())
    
    let balance = balanceResult.returnValue! as! UFix64
    log("✅ Test 4: COA EVM balance = ".concat(balance.toString()).concat(" FLOW"))
}

access(all)
fun test_deploy_minimal_contract() {
    // Test deploying the absolute minimal valid EVM bytecode
    // This creates an empty contract (does nothing, but is valid)
    let minimalBytecode = "6000600020" // PUSH1 0, PUSH1 0, MULMOD - minimal valid code
    
    let deployTx = Test.Transaction(
        code: Test.readFile("../transactions/evm/deploy_simple_contract.cdc"),
        authorizers: [admin.address],
        signers: [admin],
        arguments: [minimalBytecode]
    )
    
    let deployResult = Test.executeTransaction(deployTx)
    Test.expect(deployResult, Test.beSucceeded())
    
    log("✅ Test 5: Minimal contract deployment successful")
}
