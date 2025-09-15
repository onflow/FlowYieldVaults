import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "YieldToken"

access(all) let protocol = Test.getAccount(0x0000000000000008)
access(all) let strategies = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) let flowType = Type<@FlowToken.Vault>().identifier
access(all) let moetType = Type<@MOET.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // prices at 1.0
    setMockOraclePrice(signer: strategies, forTokenIdentifier: flowType, price: 1.0)

    // mint reserves and set mock swapper liquidity
    let reserve = 100_000_00.0
    setupMoetVault(protocol, beFailed: false)
    setupYieldVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: reserve)
    mintMoet(signer: protocol, to: protocol.address, amount: reserve, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocol.address, amount: reserve, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocol, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocol, vaultStoragePath: /storage/flowTokenVault)

    // create pool and support FLOW
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // open wrapped position (deposit protocol FLOW)
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [reserve/2.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_rebalance_with_yield_topup_recovers_target_health() {
    Test.reset(to: snapshot)
    let pid: UInt64 = 0

    // unhealthy: drop FLOW
    setMockOraclePrice(signer: strategies, forTokenIdentifier: flowType, price: 0.7)
    let h0 = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(h0 > 0 as UInt128) // basic sanity: defined

    // force rebalance on tide and position
    // Position ID is 0 for first wrapped position
    rebalancePosition(signer: protocol, pid: pid, force: true, beFailed: false)

    let h1 = getPositionHealth(pid: pid, beFailed: false)
    // Target ≈ 1.3e24 with some tolerance
    let target = UInt128(1300000000000000000000000)
    let tol = UInt128(20000000000000000000)
    Test.assert(h1 >= target - tol && h1 <= target + tol, message: "Post-rebalance health not near target 1.3")
}


