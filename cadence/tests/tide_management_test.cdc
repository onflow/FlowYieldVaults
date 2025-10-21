import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MockStrategy"

access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)

access(all) var strategyIdentifier = Type<@MockStrategy.Strategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // enable mocked Strategy creation
    addStrategyComposer(signer: tidalYieldAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@MockStrategy.StrategyComposer>().identifier,
        issuerStoragePath: MockStrategy.IssuerStoragePath,
        beFailed: false
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_CreateTideSucceeds() {
    let fundingAmount = 100.0

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(tidalYieldAccount, user)

    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    let tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)
}

access(all)
fun test_CloseTideSucceeds() {
    Test.reset(to: snapshot)

    let fundingAmount = 100.0

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(tidalYieldAccount, user)

    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    var tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    tideIDs = getTideIDs(address: user.address)
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(0, tideIDs!.length)
}
