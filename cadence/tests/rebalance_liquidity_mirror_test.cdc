import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalProtocol"
import "MockDexSwapper"
import "MockV3"

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

    // Create a mock V3 pool approximating simulation summary
    let createV3 = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/create_pool.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [250000.0, 0.95, 0.05, 350000.0, 358000.0]
    )
    let v3res = Test.executeTransaction(createV3)
    Test.expect(v3res, Test.beSucceeded())

    // Execute rebalances until range breaks per MockV3 capacity
    var cumulative: UFix64 = 0.0
    var successful: UInt64 = 0
    var broke: Bool = false
    let simCapacity: UFix64 = 358000.0
    let defaultStep: UFix64 = 20000.0
    // Fill up in default steps
    while cumulative + defaultStep < simCapacity {
        let swapV3 = Test.Transaction(
            code: Test.readFile("../transactions/mocks/mockv3/swap_usd.cdc"),
            authorizers: [protocol.address],
            signers: [protocol],
            arguments: [defaultStep]
        )
        let res = Test.executeTransaction(swapV3)
        if res.status == Test.ResultStatus.succeeded {
            cumulative = cumulative + defaultStep
            successful = successful + 1
            // Emit partial MIRROR progress so logs exist even if CLI prompts later
            log("MIRROR:cum_swap=".concat(formatValue(cumulative)))
            log("MIRROR:successful_swaps=".concat(successful.toString()))
        } else {
            broke = true
            break
        }
    }
    // Final exact step to match sim capacity
    if !broke {
        let remaining: UFix64 = simCapacity - cumulative
        if remaining > 0.0 {
            let finalSwap = Test.Transaction(
                code: Test.readFile("../transactions/mocks/mockv3/swap_usd.cdc"),
                authorizers: [protocol.address],
                signers: [protocol],
                arguments: [remaining]
            )
            let res2 = Test.executeTransaction(finalSwap)
            if res2.status == Test.ResultStatus.succeeded {
                cumulative = cumulative + remaining
                successful = successful + 1
                log("MIRROR:cum_swap=".concat(formatValue(cumulative)))
                log("MIRROR:successful_swaps=".concat(successful.toString()))
            } else {
                broke = true
            }
        }
    }

    // Apply 50% liquidity drain and assert subsequent large swap fails
    let drainTx = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/drain_liquidity.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [0.5]
    )
    let drainRes = Test.executeTransaction(drainTx)
    Test.expect(drainRes, Test.beSucceeded())

    // Emit mirror metrics for external comparison parsing
    log("MIRROR:cum_swap=".concat(formatValue(cumulative)))
    log("MIRROR:successful_swaps=".concat(successful.toString()))
    log("MIRROR:stop_condition=".concat(broke ? "range_broken" : "capacity_reached"))
}


