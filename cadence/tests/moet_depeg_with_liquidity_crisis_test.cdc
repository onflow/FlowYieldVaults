import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "MockV3"
import "MockDexSwapper"

access(all) let protocol = Test.getAccount(0x0000000000000008)
// Create agents to test liquidity-constrained deleveraging
access(all) let agent1 = Test.createAccount()
access(all) let agent2 = Test.createAccount()
access(all) let agent3 = Test.createAccount()

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

    // Setup protocol reserves
    setupMoetVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: 100000.0)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    // Configure MockDexSwapper to source from protocol MOET vault
    setMockSwapperLiquidityConnector(signer: protocol, vaultStoragePath: MOET.VaultStoragePath)

    // Create pool and support FLOW
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 10_000_000.0
    )

    // Allowlist MockDexSwapper for swaps
    let swapperTypeId = Type<MockDexSwapper.Swapper>().identifier
    let allowTx = Test.Transaction(
        code: Test.readFile("../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-governance/set_dex_liquidation_config.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [10000 as UInt16, [swapperTypeId], nil, nil, nil]
    )
    let allowRes = Test.executeTransaction(allowTx)
    Test.expect(allowRes, Test.beSucceeded())

    // Create 3 positions with MOET debt
    let agents = [agent1, agent2, agent3]
    var agentIndex: UInt64 = 0
    for agent in agents {
        mintFlow(to: agent, amount: 1000.0)
        
        let openRes = _executeTransaction(
            "../transactions/mocks/position/create_wrapped_position.cdc",
            [1000.0, /storage/flowTokenVault, true],
            agent
        )
        Test.expect(openRes, Test.beSucceeded())
        
        // Set target HF to 1.30
        let setHFRes = _executeTransaction(
            "../transactions/mocks/position/set_target_health.cdc",
            [1.30],
            agent
        )
        Test.expect(setHFRes, Test.beSucceeded())
        
        // Rebalance to reach target HF
        let rebalanceRes = _executeTransaction(
            "../transactions/mocks/position/rebalance_position.cdc",
            [agentIndex, true],
            agent
        )
        Test.expect(rebalanceRes, Test.beSucceeded())
        
        agentIndex = agentIndex + 1
    }

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_moet_depeg_with_trading() {
    safeReset()
    let agents = [agent1, agent2, agent3]
    let pids: [UInt64] = [0, 1, 2]

    // Measure HF before depeg
    var avgHFBefore = 0.0 as UFix128
    var totalDebtBefore = 0.0
    
    for pid in pids {
        let hf = getPositionHealth(pid: pid, beFailed: false)
        avgHFBefore = avgHFBefore + hf
        
        let details = getPositionDetails(pid: pid, beFailed: false)
        let debtOpt = findBalance(details: details, vaultType: Type<@MOET.Vault>())
        if debtOpt != nil {
            totalDebtBefore = totalDebtBefore + debtOpt!
        }
    }
    avgHFBefore = avgHFBefore / UFix128(agents.length)
    
    log("MIRROR:avg_hf_before=".concat(formatHF(avgHFBefore)))
    log("MIRROR:total_debt_before=".concat(formatValue(totalDebtBefore)))
    log("MIRROR:agent_count=".concat(agents.length.toString()))

    // MOET DEPEG: Price drops to 0.95
    setMockOraclePrice(signer: protocol, forTokenIdentifier: moetType, price: 0.95)

    // Create MOET pool with LIMITED liquidity (simulating 50% drain)
    // Pool only has enough capacity for ~1.5 agents to deleverage
    let createV3 = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/create_pool.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [250000.0, 0.95, 0.05, 100000.0, 150000.0]  // Limited capacity
    )
    let v3res = Test.executeTransaction(createV3)
    Test.expect(v3res, Test.beSucceeded())

    // Measure HF immediately after depeg (before trading)
    var minHFAtDepeg = 999.0 as UFix128
    var sumHFAtDepeg = 0.0 as UFix128
    
    for pid in pids {
        let hf = getPositionHealth(pid: pid, beFailed: false)
        if hf < minHFAtDepeg { minHFAtDepeg = hf }
        sumHFAtDepeg = sumHFAtDepeg + hf
    }
    
    let avgHFAtDepeg = sumHFAtDepeg / UFix128(agents.length)
    
    log("MIRROR:hf_min_at_depeg=".concat(formatHF(minHFAtDepeg)))
    log("MIRROR:hf_avg_at_depeg=".concat(formatHF(avgHFAtDepeg)))

    // Now agents try to REDUCE MOET debt by swapping collateral -> MOET
    // This simulates deleveraging through the illiquid MOET pool
    var successfulDeleverages = 0
    var failedDeleverages = 0
    var totalSlippageLoss = 0.0

    var agentIndex: UInt64 = 0
    for agent in agents {
        // Each agent tries to swap ~10% of collateral to reduce MOET debt
        // Through the drained pool, this will have high slippage
        let swapAmount = 100.0  // Swap 100 FLOW worth
        
        let swapTx = Test.Transaction(
            code: Test.readFile("../transactions/mocks/mockv3/swap_usd.cdc"),
            authorizers: [protocol.address],
            signers: [protocol],
            arguments: [swapAmount]
        )
        let swapRes = Test.executeTransaction(swapTx)
        
        if swapRes.status == Test.ResultStatus.succeeded {
            successfulDeleverages = successfulDeleverages + 1
            // In reality, agent would use swapped MOET to reduce debt
            // For simplicity, we're just measuring pool exhaustion
        } else {
            failedDeleverages = failedDeleverages + 1
        }
        
        agentIndex = agentIndex + 1
    }
    
    log("MIRROR:successful_deleverages=".concat(successfulDeleverages.toString()))
    log("MIRROR:failed_deleverages=".concat(failedDeleverages.toString()))

    // Measure final HF after attempted deleveraging
    var minHFFinal = 999.0 as UFix128
    var sumHFFinal = 0.0 as UFix128
    
    for pid in pids {
        let hf = getPositionHealth(pid: pid, beFailed: false)
        if hf < minHFFinal { minHFFinal = hf }
        sumHFFinal = sumHFFinal + hf
    }
    
    let avgHFFinal = sumHFFinal / UFix128(agents.length)
    
    log("MIRROR:hf_min=".concat(formatHF(minHFFinal)))
    log("MIRROR:hf_avg_final=".concat(formatHF(avgHFFinal)))

    // Calculate HF change
    let hfChange = avgHFFinal - avgHFAtDepeg
    log("MIRROR:hf_change=".concat(formatHF(hfChange)))

    // Summary: In atomic protocol behavior, MOET depeg improves HF
    // But with liquidity-constrained trading, agents can't capitalize on it
    // and may even worsen their position trying to deleverage
    let poolExhausted = failedDeleverages > 0
    log("MIRROR:pool_exhausted=".concat(poolExhausted ? "true" : "false"))
    
    // Note: HF should still be >= hf_before in most cases since debt token value decreased
    // But the inability to deleverage through illiquid pools represents missed opportunity
    // In simulation, agents actively trading through drained pools see HF of 0.775
    // due to slippage losses and failed deleveraging attempts
}

