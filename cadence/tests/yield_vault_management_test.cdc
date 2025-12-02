import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MockStrategy"

access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)

access(all) var strategyIdentifier = Type<@MockStrategy.Strategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // enable mocked Strategy creation
    addStrategyComposer(signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@MockStrategy.StrategyComposer>().identifier,
        issuerStoragePath: MockStrategy.IssuerStoragePath,
        beFailed: false
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_CreateYieldVaultSucceeds() {
    let fundingAmount = 100.0

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)
}

access(all)
fun test_CloseYieldVaultSucceeds() {
    Test.reset(to: snapshot)

    let fundingAmount = 100.0

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

    yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(0, yieldVaultIDs!.length)
}
