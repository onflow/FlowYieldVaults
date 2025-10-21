import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "MockDexSwapper"

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

    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 1.0)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 1.0)

    setupMoetVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: 100000.0)
    mintMoet(signer: protocol, to: protocol.address, amount: 100000.0, beFailed: false)

    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    // Baseline collateral factor 0.8
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_cf_baseline_no_liquidation_at_85pct() {
    safeReset()
    let pid: UInt64 = 0

    // 15% drop to FLOW price 0.85
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.85)

    // Health should remain above ~1.0 with baseline CF
    let h = getPositionHealth(pid: pid, beFailed: false)
    let minHealthy = 1010000000000000000000000 as UInt128 // 1.01
    Test.assert(h >= minHealthy)

    // Governance allowlist of MockDexSwapper
    let swapperTypeId = Type<MockDexSwapper.Swapper>().identifier
    let allowTx = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-governance/set_dex_liquidation_config.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [10000 as UInt16, [swapperTypeId], nil, nil, nil]
    )
    let allowRes = Test.executeTransaction(allowTx)
    Test.expect(allowRes, Test.beSucceeded())

    // Attempt liquidation: should fail because HF >= 1
    setupMoetVault(protocol, beFailed: false)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    let liqTx = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.17647059]
    )
    let liqRes = Test.executeTransaction(liqTx)
    Test.expect(liqRes, Test.beFailed())
}


