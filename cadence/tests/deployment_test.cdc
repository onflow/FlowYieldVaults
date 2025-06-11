import Test
import BlockchainHelpers

import "test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_DeploymentSuccess() {
    log("Success: Contracts deployed")
}