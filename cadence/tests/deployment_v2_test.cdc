import Test
import BlockchainHelpers

import "test_helpers.cdc"

access(all)
fun setup() {
    deployContractsV2()
}

access(all)
fun test_DeploymentV2Success() {
    log("Success: V2 Contracts deployed")
} 