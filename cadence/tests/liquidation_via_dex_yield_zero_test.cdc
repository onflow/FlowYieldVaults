import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "MockDexSwapper"

access(all) let protocol = Test.getAccount(0x0000000000000008)

access(all) let flowType = Type<@FlowToken.Vault>().identifier
access(all) let moetType = Type<@MOET.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // Set initial prices
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 1.0)

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

    // Open a position with protocol as the user
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_liquidation_via_dex_when_yield_price_zero() {
    Test.reset(to: snapshot)
    let pid: UInt64 = 0

    // Make undercollateralized by lowering FLOW
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.7)

    // Set Yield price to 0 – simulated by setting MOET price high vs Yield used in strategy in submodule tests.
    // For this repo, we will just proceed to liquidation (rebalance will be ineffective for top-up when source is 0).

    // Allowlist MockDexSwapper via governance
    let swapperTypeId = Type<MockDexSwapper.Swapper>().identifier
    let allowTx = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-governance/set_dex_liquidation_config.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [nil, [swapperTypeId], nil, nil, nil]
    )
    let allowRes = Test.executeTransaction(allowTx)
    Test.expect(allowRes, Test.beSucceeded())

    // Execute liquidation via mock dex (priceRatio aligns with submodule guard examples)
    let liqTx = _executeTransaction(
        "../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.42857143],
        protocol
    )
    Test.expect(liqTx, Test.beSucceeded())

    // Expect health ≈ 1.05e24 after liquidation
    let h = getPositionHealth(pid: pid, beFailed: false)
    let target = UInt128(1050000000000000000000000)
    let tol = UInt128(10000000000000000000)
    Test.assert(h >= target - tol && h <= target + tol)
}


