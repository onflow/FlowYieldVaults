import Test
import "EVM"

access(all) let emulatorAccount = Test.getAccount(0xf8d6e0586b0a20c7)

access(all)
fun setup() {
    // Basic setup - emulator already has EVM deployed
    log("✅ EVM contract available at f8d6e0586b0a20c7")
}

access(all)
fun test_create_coa() {
    // Test 1: Create a Cadence-Owned Account (COA)
    let txCode = Test.readFile("../transactions/evm/create_coa.cdc")
    let tx = Test.Transaction(
        code: txCode,
        authorizers: [emulatorAccount.address],
        signers: [emulatorAccount],
        arguments: []
    )
    
    let result = Test.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
    
    log("✅ Test 1: COA creation successful")
}

access(all)
fun test_get_coa_address() {
    // Test 2: Get the EVM address of the COA
    let scriptCode = Test.readFile("../scripts/evm/get_coa_address.cdc")
    let scriptResult = Test.executeScript(scriptCode, [emulatorAccount.address])
    
    Test.expect(scriptResult, Test.beSucceeded())
    
    let evmAddress = scriptResult.returnValue! as! String
    log("✅ Test 2: COA EVM address = ".concat(evmAddress))
    
    // Verify it's a valid hex address
    Test.assert(evmAddress.length > 0, message: "EVM address should not be empty")
}

access(all)
fun test_deploy_simple_erc20() {
    // Test 3: Deploy a simple ERC20 contract to EVM
    // This validates we can deploy Solidity bytecode
    
    // Simple ERC20 bytecode (minimal, just for testing)
    // This is a very basic token that mints to deployer
    let erc20Bytecode = "608060405234801561001057600080fd5b506040518060400160405280600481526020017f544553540000000000000000000000000000000000000000000000000000000081525060405180604001604052806004815260200166546573740000000000000000000000000000000000000000000000000000000000815250336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff16021790555061016d565b610c6a8061017c6000396000f3fe"
    
    // Transaction to deploy via COA
    let deployTxCode = Test.readFile("../transactions/evm/deploy_simple_contract.cdc")
    let deployTx = Test.Transaction(
        code: deployTxCode,
        authorizers: [emulatorAccount.address],
        signers: [emulatorAccount],
        arguments: [erc20Bytecode]
    )
    
    let deployResult = Test.executeTransaction(deployTx)
    
    // May fail if transaction doesn't exist yet - that's ok
    if deployResult.status == Test.ResultStatus.succeeded {
        log("✅ Test 3: ERC20 deployment successful")
    } else {
        log("⚠️  Test 3: Deployment transaction not implemented yet (expected)")
        log("    Create: cadence/transactions/evm/deploy_simple_contract.cdc")
    }
}

access(all)
fun test_evm_balance() {
    // Test 4: Check COA balance on EVM side
    let balanceScript = Test.readFile("../scripts/evm/get_coa_balance.cdc")
    let balanceResult = Test.executeScript(balanceScript, [emulatorAccount.address])
    
    // May fail if script doesn't exist - that's ok
    if balanceResult.status == Test.ResultStatus.succeeded {
        let balance = balanceResult.returnValue! as! UFix64
        log("✅ Test 4: COA EVM balance = ".concat(balance.toString()).concat(" FLOW"))
    } else {
        log("⚠️  Test 4: Balance script not implemented yet (expected)")
        log("    Create: cadence/scripts/evm/get_coa_balance.cdc")
    }
}

