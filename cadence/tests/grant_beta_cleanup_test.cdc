import Test

import "test_helpers.cdc"

import "FlowYieldVaultsClosedBeta"

access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_ReGrantBetaRevokesPreviousCapability() {
    let user = Test.createAccount()
    transferFlow(signer: serviceAccount, recipient: user.address, amount: 1.0)

    grantBeta(flowYieldVaultsAccount, user)

    let backupRes = _executeTransaction("../transactions/test/backup_beta_cap.cdc", [], user)
    Test.expect(backupRes, Test.beSucceeded())

    // Re-granting should revoke the previously issued controller (and thus all old capability copies).
    grantBeta(flowYieldVaultsAccount, user)

    // Event assertions: the re-grant should emit BetaRevoked for the *previous* capID, then a fresh BetaGranted.
    let grantedAny = Test.eventsOfType(Type<FlowYieldVaultsClosedBeta.BetaGranted>())
    var userGrants: [FlowYieldVaultsClosedBeta.BetaGranted] = []
    for evt in grantedAny {
        let g = evt as! FlowYieldVaultsClosedBeta.BetaGranted
        if g.addr == user.address {
            userGrants.append(g)
        }
    }
    Test.assertEqual(2, userGrants.length)

    let revokedAny = Test.eventsOfType(Type<FlowYieldVaultsClosedBeta.BetaRevoked>())
    var userRevokes: [FlowYieldVaultsClosedBeta.BetaRevoked] = []
    for evt in revokedAny {
        let r = evt as! FlowYieldVaultsClosedBeta.BetaRevoked
        if r.addr == user.address {
            userRevokes.append(r)
        }
    }
    Test.assertEqual(1, userRevokes.length)
    Test.assert(userRevokes[0].capID != nil, message: "Expected revoke capID to be non-nil")
    Test.assertEqual(userGrants[0].capID, userRevokes[0].capID!)
    Test.assert(userGrants[0].capID != userGrants[1].capID, message: "Expected a fresh capID on re-grant")

    let assertRes = _executeTransaction("../transactions/test/assert_backup_beta_cap_revoked.cdc", [], user)
    Test.expect(assertRes, Test.beSucceeded())
}
