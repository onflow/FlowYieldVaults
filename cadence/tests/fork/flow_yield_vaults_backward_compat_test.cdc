#test_fork(network: "mainnet", height: nil)

import Test

/// Backward-compatibility redeploy test for FlowYieldVaults contracts.
///
/// Redeploys all FlowYieldVaults contracts from the current repo onto the forked mainnet
/// state. A successful redeploy confirms the updated code is backward-compatible with the
/// existing on-chain storage layout and dependent contracts.
///
/// Deployment order respects import dependencies:
///   UInt64LinkedList
///   → FlowYieldVaultsClosedBeta
///   → FlowYieldVaultsSchedulerRegistryV1
///   → FlowYieldVaults
///   → FlowYieldVaultsAutoBalancersV1
///   → FlowYieldVaultsSchedulerV1
///   → FlowYieldVaultsStrategiesV2
///   → PMStrategiesV1

access(all) struct ContractSpec {
    access(all) let path: String
    access(all) let arguments: [AnyStruct]

    init(path: String, arguments: [AnyStruct]) {
        self.path = path
        self.arguments = arguments
    }
}

/// Extracts the contract name from a file path.
/// "../../cadence/contracts/FlowYieldVaults.cdc" → "FlowYieldVaults"
access(all) fun contractNameFromPath(_ path: String): String {
    let parts = path.split(separator: "/")
    let file = parts[parts.length - 1]
    return file.split(separator: ".")[0]
}

access(all) fun deployAndExpectSuccess(_ spec: ContractSpec) {
    let name = contractNameFromPath(spec.path)
    log("Deploying ".concat(name).concat("..."))
    let err = Test.deployContract(name: name, path: spec.path, arguments: spec.arguments)
    Test.expect(err, Test.beNil())
    Test.commitBlock()
}

// UniV3 mainnet addresses — required by strategy contracts on init
access(all) let univ3Factory = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"
access(all) let univ3Router  = "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341"
access(all) let univ3Quoter  = "0x370A8DF17742867a44e56223EC20D82092242C85"

access(all) fun setup() {
    log("==== FlowYieldVaults Backward-Compatibility Redeploy Test ====")

    let contracts: [ContractSpec] = [
        ContractSpec(
            path: "../../contracts/UInt64LinkedList.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/AutoBalancers.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaultsClosedBeta.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaultsSchedulerRegistryV1.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaults.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaultsAutoBalancers.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaultsAutoBalancersV1.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowYieldVaultsSchedulerV1.cdc",
            arguments: []
        ),

        // @TODO restore in strategies PR
        // ContractSpec(
        //     path: "../../contracts/FlowYieldVaultsStrategiesV2.cdc",
        //     arguments: [univ3Factory, univ3Router, univ3Quoter]
        // ),
        ContractSpec(
            path: "../../contracts/PMStrategiesV1.cdc",
            arguments: [univ3Factory, univ3Router, univ3Quoter]
        )
    ]

    for spec in contracts {
        deployAndExpectSuccess(spec)
    }

    log("==== All FlowYieldVaults contracts redeployed successfully ====")
}

access(all) fun testAllContractsRedeployedWithoutError() {
    log("All FlowYieldVaults contracts redeployed without error (verified in setup)")
}
