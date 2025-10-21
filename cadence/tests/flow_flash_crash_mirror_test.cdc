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

    // Initial prices aligning to simulation defaults for FLOW-adjacent tests
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 1.0)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 1.0)

    // Setup protocol reserves and MOET vault
    setupMoetVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: 100000.0)
    mintMoet(signer: protocol, to: protocol.address, amount: 100000.0, beFailed: false)

    // Create pool and support FLOW with baseline CF
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open a wrapped position to mirror simulation agents opening exposure
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_flow_flash_crash_liquidation_path() {
    safeReset()
    let pid: UInt64 = 0

    // Apply a flash crash to FLOW (e.g., -30%) akin to simulation stress
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.7)

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

    // Ensure protocol has MOET liquidity for DEX swap
    setupMoetVault(protocol, beFailed: false)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    // Execute liquidation via mock dex when undercollateralized
    let liqTx = _executeTransaction(
        "../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.42857143],
        protocol
    )
    Test.expect(liqTx, Test.beSucceeded())

    // Post-liquidation health should recover above 1.0 (tolerance window)
    let h = getPositionHealth(pid: pid, beFailed: false)
    let target = 1010000000000000000000000 as UInt128
    let tol = 10000000000000000000 as UInt128
    Test.assert(h >= target - tol)
}


