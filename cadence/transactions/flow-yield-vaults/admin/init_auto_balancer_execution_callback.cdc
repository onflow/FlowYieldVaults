import "FlowYieldVaultsAutoBalancers"

/// Ensures the shared AutoBalancer execution callback is published at the
/// canonical DeFiActions public path.
///
/// Idempotent: safe to call after deploying or updating FlowYieldVaultsAutoBalancers.
///
/// Deployment/update ordering:
/// 1. deploy or update DeFiActions first
/// 2. deploy or update FlowYieldVaultsAutoBalancers
/// 3. run this transaction as the FlowYieldVaults contract account
transaction() {
    prepare(_ signer: auth(BorrowValue) &Account) {}

    execute {
        FlowYieldVaultsAutoBalancers.initRegistryReportCallback()
    }
}
