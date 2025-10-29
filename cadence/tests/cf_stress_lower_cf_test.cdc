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
    // Lower collateral factor by ~10% to 0.72
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.72,
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
fun test_cf_lower_triggers_liquidation_at_85pct() {
    safeReset()
    let pid: UInt64 = 0

    // 15% drop to FLOW price 0.85
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.85)

    // Expect HF to be below 1.0 now
    let h = getPositionHealth(pid: pid, beFailed: false)
    let one = 1000000000000000000000000 as UInt128
    Test.assert(h < one)

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

    // Provide MOET and liquidate via mock dex
    setupMoetVault(protocol, beFailed: false)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    let liqTx = _executeTransaction(
        "../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.17647059],
        protocol
    )
    Test.expect(liqTx, Test.beSucceeded())

    // After liquidation, HF should be >= 1.0
    let hAfter = getPositionHealth(pid: pid, beFailed: false)
    let minHealthy = 1010000000000000000000000 as UInt128
    Test.assert(hAfter >= minHealthy)
}


