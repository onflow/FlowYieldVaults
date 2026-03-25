import "DeFiActions"

/// Test-only transaction that simulates an arbitrary account invoking the publicly
/// published AutoBalancer execution callback directly.
///
/// This is the exact surface area the FYV hardening is defending. The transaction
/// intentionally does not use any privileged capability or account access.
transaction(ownerAddress: Address, resourceUUID: UInt64, uniqueID: UInt64) {

    prepare(_ signer: &Account) {
        let callback = getAccount(ownerAddress).capabilities.borrow<&{DeFiActions.AutoBalancerExecutionCallback}>(
            DeFiActions.executionCallbackPublicPath()
        ) ?? panic("Missing public AutoBalancer execution callback")

        callback.onExecuted(resourceUUID: resourceUUID, uniqueID: uniqueID)
    }
}
