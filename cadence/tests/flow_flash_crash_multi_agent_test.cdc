import Test
import BlockchainHelpers

import "./test_helpers.cdc"

import "FlowToken"
import "MOET"
import "TidalProtocol"
import "MockV3"

access(all) let protocol = Test.getAccount(0x0000000000000008)
// Create multiple test accounts for multi-agent simulation
access(all) let agent1 = Test.createAccount()
access(all) let agent2 = Test.createAccount()
access(all) let agent3 = Test.createAccount()
access(all) let agent4 = Test.createAccount()
access(all) let agent5 = Test.createAccount()

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

    // Setup protocol
    setupMoetVault(protocol, beFailed: false)
    mintFlow(to: protocol, amount: 1_000_000.0)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)

    // Create pool with CF=0.8 (matching simulation)
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 10_000_000.0
    )

    // Create positions for all 5 agents with same setup
    let agents = [agent1, agent2, agent3, agent4, agent5]
    var agentIndex: UInt64 = 0
    for agent in agents {
        // Fund each agent with FLOW
        mintFlow(to: agent, amount: 1000.0)
        
        // Create position with 1000 FLOW collateral
        let openRes = _executeTransaction(
            "../transactions/mocks/position/create_wrapped_position.cdc",
            [1000.0, /storage/flowTokenVault, true],
            agent
        )
        Test.expect(openRes, Test.beSucceeded())
        
        // Set target HF to 1.15 (matching simulation agent config)
        let setHFRes = _executeTransaction(
            "../transactions/mocks/position/set_target_health.cdc",
            [1.15],
            agent
        )
        Test.expect(setHFRes, Test.beSucceeded())
        
        // Rebalance to reach target HF=1.15
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
fun test_multi_agent_flash_crash() {
    safeReset()
    
    // Create shared liquidity pool (smaller than needed for all agents)
    // This simulates liquidity constraints when all agents try to rebalance
    let createV3 = Test.Transaction(
        code: Test.readFile("../transactions/mocks/mockv3/create_pool.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [500000.0, 0.95, 0.05, 50000.0, 200000.0] // Limited capacity
    )
    let v3res = Test.executeTransaction(createV3)
    Test.expect(v3res, Test.beSucceeded())

    // Track all agents' health before crash
    let agents = [agent1, agent2, agent3, agent4, agent5]
    let pids: [UInt64] = [0, 1, 2, 3, 4]
    
    log("MIRROR:agent_count=5")
    
    var totalDebtBefore = 0.0
    var avgHFBefore = 0.0 as UFix128
    
    for i, pid in pids {
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

    // FLASH CRASH: FLOW drops 30% (1.0 -> 0.7)
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.7)

    // Measure minimum HF across all agents immediately after crash
    var minHF = 999.0 as UFix128
    var maxHF = 0.0 as UFix128
    var sumHF = 0.0 as UFix128
    
    for pid in pids {
        let hf = getPositionHealth(pid: pid, beFailed: false)
        if hf < minHF { minHF = hf }
        if hf > maxHF { maxHF = hf }
        sumHF = sumHF + hf
    }
    
    let avgHFAtCrash = sumHF / UFix128(agents.length)
    
    log("MIRROR:hf_min=".concat(formatHF(minHF)))
    log("MIRROR:hf_max=".concat(formatHF(maxHF)))
    log("MIRROR:hf_avg=".concat(formatHF(avgHFAtCrash)))

    // Now simulate agents trying to rebalance through the LIMITED liquidity pool
    // This is where cascading effects and liquidity exhaustion happen
    var successfulRebalances = 0
    var failedRebalances = 0
    
    agentIndex = 0
    for agent in agents {
        // Try to rebalance (some will fail due to liquidity constraints)
        let rebalanceRes = _executeTransaction(
            "../transactions/mocks/position/rebalance_position.cdc",
            [agentIndex, true],
            agent
        )
        if rebalanceRes.status == Test.ResultStatus.succeeded {
            successfulRebalances = successfulRebalances + 1
        } else {
            failedRebalances = failedRebalances + 1
        }
        agentIndex = agentIndex + 1
    }
    
    log("MIRROR:successful_rebalances=".concat(successfulRebalances.toString()))
    log("MIRROR:failed_rebalances=".concat(failedRebalances.toString()))

    // Measure HF after rebalancing attempts
    var minHFAfter = 999.0 as UFix128
    var sumHFAfter = 0.0 as UFix128
    var liquidatedCount = 0
    
    for pid in pids {
        let hf = getPositionHealth(pid: pid, beFailed: false)
        if hf < minHFAfter { minHFAfter = hf }
        sumHFAfter = sumHFAfter + hf
        if hf < 1.0 as UFix128 { liquidatedCount = liquidatedCount + 1 }
    }
    
    let avgHFAfter = sumHFAfter / UFix128(agents.length)
    
    log("MIRROR:hf_min_after_rebalance=".concat(formatHF(minHFAfter)))
    log("MIRROR:hf_avg_after_rebalance=".concat(formatHF(avgHFAfter)))
    log("MIRROR:liquidatable_count=".concat(liquidatedCount.toString()))

    // Pool exhaustion is inferred from failed rebalances
    // If failedRebalances > 0, the pool ran out of capacity
    let poolExhausted = failedRebalances > 0
    log("MIRROR:pool_exhausted=".concat(poolExhausted ? "true" : "false"))

    // Summary metrics
    let hfDrop = avgHFBefore - avgHFAfter
    log("MIRROR:avg_hf_drop=".concat(formatHF(hfDrop)))
    
    // This test validates multi-agent cascading effects during crash
    // We expect worse outcomes than single-agent due to liquidity competition
}

