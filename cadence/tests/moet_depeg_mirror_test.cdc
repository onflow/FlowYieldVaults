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
    // NOTE: This test validates ATOMIC protocol behavior where MOET depeg improves HF
    // (debt value decreases). The simulation's lower HF (0.775) includes agent rebalancing
    // losses through 50% drained liquidity pools. For multi-agent scenario with
    // liquidity-constrained trading, see moet_depeg_with_liquidity_crisis_test.cdc.
    // 
    // This test correctly shows HF improvement when debt token depegs.
    // Simulation includes trading dynamics and slippage losses not captured here.
    
    safeReset()
    let pid: UInt64 = 0

    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_before=".concat(formatHF(hBefore)))

    // MOET depeg to 0.95 (debt token price down)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 0.95)

    // Create a mock V3 pool approximating simulation summary
    let createV3 = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/create_pool.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [250000.0, 0.95, 0.05, 350000.0, 358000.0]
    )
    let v3res = Test.executeTransaction(createV3)
    Test.expect(v3res, Test.beSucceeded())

    // Apply 50% liquidity drain
    let drainTx = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/drain_liquidity.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [0.5]
    )
    let drainRes = Test.executeTransaction(drainTx)
    Test.expect(drainRes, Test.beSucceeded())

    let hMin = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_min=".concat(formatHF(hMin)))

    let hAfter = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_after=".concat(formatHF(hAfter)))

    // Expect HF not to decrease due to lower debt token price (allow small tolerance)
    let tol = 0.01 as UFix128
    Test.assert(hAfter + tol >= hBefore)
}


