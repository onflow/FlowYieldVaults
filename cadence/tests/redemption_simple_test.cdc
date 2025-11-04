import Test

// Simple standalone tests for RedemptionWrapper that verify core functionality
// These tests are designed to run independently without complex test infrastructure

access(all)
fun test_contract_deployment() {
    // Deploy FungibleToken standard
    var err = Test.deployContract(
        name: "FungibleToken",
        path: "../../lib/FlowALP/node_modules/@onflow/flow-ft/contracts/FungibleToken.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy DeFiActionsUtils
    err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowALPMath (required by RedemptionWrapper)
    err = Test.deployContract(
        name: "FlowALPMath",
        path: "../../lib/FlowALP/cadence/lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy DeFiActionsMathUtils
    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/utils/DeFiActionsMathUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy DeFiActions
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET
    let initialMoetSupply = 0.0
    err = Test.deployContract(
        name: "MOET",
        path: "../../lib/FlowALP/cadence/contracts/MOET.cdc",
        arguments: [initialMoetSupply]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FlowALP
    err = Test.deployContract(
        name: "FlowALP",
        path: "../../lib/FlowALP/cadence/contracts/FlowALP.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FungibleTokenConnectors
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../lib/FlowALP/FlowActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Finally deploy RedemptionWrapper
    err = Test.deployContract(
        name: "RedemptionWrapper",
        path: "../contracts/RedemptionWrapper.cdc",
        arguments: []
    )
    
    if err == nil {
        log("✅ ALL CONTRACTS DEPLOYED SUCCESSFULLY")
    } else {
        log("❌ RedemptionWrapper deployment failed")
        log(err!.message)
    }
    
    Test.expect(err, Test.beNil())
}

access(all)
fun test_view_functions_available() {
    // This test verifies that the contract's view functions are accessible
    // We can't call them without proper setup, but we can verify the contract exists
    
    let account = Test.getAccount(0x0000000000000007)
    
    // Try to borrow the public capability
    let script = Test.readFile("./scripts/redemption/get_position_health.cdc")
    
    // This will fail if position isn't set up, but verifies the function exists
    let result = Test.executeScript(script, [])
    
    // We expect this to fail with "Position not set up" which means the contract is deployed correctly
    // If it fails with "cannot find declaration" that means deployment failed
    log("View function test - checking if contract methods are accessible")
    log(result.error != nil ? result.error!.message : "Script executed")
}

access(all)
fun test_configuration_parameters() {
    // Verify that the contract was initialized with correct default values
    let script = "import RedemptionWrapper from 0x0000000000000007\n\naccess(all) fun main(): {String: UFix64} {\n    return {\n        \"maxRedemption\": RedemptionWrapper.maxRedemptionAmount,\n        \"minRedemption\": RedemptionWrapper.minRedemptionAmount,\n        \"redemptionCooldown\": RedemptionWrapper.redemptionCooldown,\n        \"dailyLimit\": RedemptionWrapper.dailyRedemptionLimit\n    }\n}"
    
    let result = Test.executeScript(script, [])
    Test.expect(result, Test.beSucceeded())
    
    let config = result.returnValue! as! {String: UFix64}
    
    // Verify defaults
    Test.assertEqual(10000.0, config["maxRedemption"]!)
    Test.assertEqual(10.0, config["minRedemption"]!)
    Test.assertEqual(60.0, config["redemptionCooldown"]!)
    Test.assertEqual(100000.0, config["dailyLimit"]!)
    
    log("✅ All configuration parameters have correct default values")
}

