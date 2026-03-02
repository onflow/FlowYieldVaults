import Test

import "test_helpers.cdc"

access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_CreateYieldVaultManagerValidatesBetaRef() {
    // Swap in a test-only FlowYieldVaultsClosedBeta implementation where `validateBeta` always returns false.
    // This lets us assert that `FlowYieldVaults.createYieldVaultManager` actually calls `validateBeta`.
    let err = Test.deployContract(
        name: "FlowYieldVaultsClosedBeta",
        path: "../contracts/mocks/FlowYieldVaultsClosedBeta_validate_beta_false.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    let user = Test.createAccount()
    transferFlow(signer: serviceAccount, recipient: user.address, amount: 1.0)
    grantBeta(flowYieldVaultsAccount, user)

    let txn = Test.Transaction(
        code: Test.readFile("../transactions/test/create_yield_vault_manager_with_beta_cap.cdc"),
        authorizers: [user.address],
        signers: [user],
        arguments: []
    )
    let res = Test.executeTransaction(txn)
    Test.expect(res, Test.beFailed())
    Test.assert(res.error != nil, message: "Expected transaction to fail with an error")
    let errorMessage = res.error!.message
    Test.assert(
        errorMessage.contains("Invalid Beta Ref"),
        message: "Unexpected error message: ".concat(errorMessage)
    )
}
