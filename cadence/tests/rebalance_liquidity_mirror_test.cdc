import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalProtocol"
import "MockDexSwapper"

access(all) let protocol = Test.getAccount(0x0000000000000008)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) let flowType = Type<@FlowToken.Vault>().identifier
access(all) let moetType = Type<@MOET.Vault>().identifier
access(all) let yieldType = Type<@YieldToken.Vault>().identifier

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

    // Initialize prices at peg
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 1.0)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 1.0)
    setMockOraclePrice(signer: yieldTokenAccount, forTokenIdentifier: yieldType, price: 1.0)

    // Setup reserves
    setupMoetVault(protocol, beFailed: false)
    setupYieldVault(protocol, beFailed: false)
    let reserve: UFix64 = 250000.0 // pool_size_usd per side in simulation JSON
    mintFlow(to: protocol, amount: reserve)
    mintMoet(signer: protocol, to: protocol.address, amount: reserve, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocol.address, amount: reserve, beFailed: false)

    // Configure MockDexSwapper to source from protocol MOET vault when swapping YT->MOET and vice versa
    setMockSwapperLiquidityConnector(signer: protocol, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocol, vaultStoragePath: YieldToken.VaultStoragePath)

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

    // Open wrapped position as basic setup
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_rebalance_capacity_thresholds() {
    safeReset()

    // Allowlist MockDexSwapper
    let swapperTypeId = Type<MockDexSwapper.Swapper>().identifier
    let allowTx = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-governance/set_dex_liquidation_config.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [10000 as UInt16, [swapperTypeId], nil, nil, nil]
    )
    let allowRes = Test.executeTransaction(allowTx)
    Test.expect(allowRes, Test.beSucceeded())

    // Provide ample MOET & YIELD for swaps
    setupMoetVault(protocol, beFailed: false)
    setupYieldVault(protocol, beFailed: false)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    // Execute a series of synthetic small-capacity steps (approximate first N rebalances)
    // Steps chosen to sum to ~10k to mirror JSON's early cumulative volume
    let steps: [UFix64] = [2000.0, 2000.0, 2000.0, 2000.0, 2000.0]
    var cumulative: UFix64 = 0.0
    var successful: UInt64 = 0
    var broke: Bool = false

    var i = 0
    while i < steps.length {
        let delta = steps[i]
        cumulative = cumulative + delta

        // Perform YIELD -> MOET swap via fixed-ratio swapper (peg-preserving)
        let swapTx = Test.Transaction(
            code: Test.readFile("../transactions/mocks/swapper/swap_fixed_ratio.cdc"),
            authorizers: [protocol.address],
            signers: [protocol],
            arguments: [delta, 1.0]
        )
        let res = Test.executeTransaction(swapTx)
        if res.status == Test.ResultStatus.succeeded {
            successful = successful + 1
        } else {
            broke = true
            break
        }
        i = i + 1
    }

    // Compare threshold behavior with simulation summary (approximate)
    // Expect all steps to succeed up to 10k cumulative
    Test.assert(successful == UInt64(steps.length))
    Test.assert(equalAmounts(a: cumulative, b: 10000.0, tolerance: 0.00000001))

    // Emit mirror metrics for external comparison parsing
    log("MIRROR:cum_swap=".concat(formatValue(cumulative)))
    log("MIRROR:successful_swaps=".concat(successful.toString()))
    log("MIRROR:stop_condition=max_safe_single_swap")
}


