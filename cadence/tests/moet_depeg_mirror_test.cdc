import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"

access(all) let protocol = Test.getAccount(0x0000000000000008)

access(all) let flowType = Type<@FlowToken.Vault>().identifier
access(all) let moetType = Type<@MOET.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()

    // Initial prices
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 1.0)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 1.0)

    // Setup protocol reserves and MOET vault
    setupMoetVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: 100000.0)
    mintMoet(signer: protocol, to: protocol.address, amount: 100000.0, beFailed: false)

    // Create pool and support FLOW
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open a position
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_moet_depeg_health_resilience() {
    safeReset()
    let pid: UInt64 = 0

    let hBefore = getPositionHealth(pid: pid, beFailed: false)

    // MOET depeg to 0.95 (debt token price down)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 0.95)

    let hAfter = getPositionHealth(pid: pid, beFailed: false)

    // Expect HF not to decrease due to lower debt token price (allow small tolerance)
    let tol = 10000000000000000000 as UInt128
    Test.assert(hAfter + tol >= hBefore)
}


