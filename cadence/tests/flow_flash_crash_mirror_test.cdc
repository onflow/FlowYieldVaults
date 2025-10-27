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

    // Create pool and support FLOW with CF=0.8 to match simulation (BTC equivalent)
    createAndStorePool(signer: protocol, defaultTokenIdentifier: moetType, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowType,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open a wrapped position (initially borrows to HF=1.3 protocol default)
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        protocol
    )
    Test.expect(openRes, Test.beSucceeded())
    
    // Set target HF to 1.15 to match simulation agents
    let setHFRes = _executeTransaction(
        "../transactions/mocks/position/set_target_health.cdc",
        [1.15],
        protocol
    )
    Test.expect(setHFRes, Test.beSucceeded())
    
    // Force rebalance to adjust to the new target HF=1.15
    // With CF=0.8: effective_collateral = 1000 * 1.0 * 0.8 = 800
    // Target debt for HF=1.15: 800 / 1.15 = 695.65 (vs 615.38 at HF=1.3)
    let pid: UInt64 = 0
    let rebalRes = _executeTransaction(
        "../transactions/mocks/position/rebalance_position.cdc",
        [pid, true],
        protocol
    )
    Test.expect(rebalRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_flow_flash_crash_liquidation_path() {
    safeReset()
    let pid: UInt64 = 0

    // Pre-crash health
    let hfBefore = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_before=".concat(formatHF(hfBefore)))

    // Emit pre-crash collateral and debt to confirm scale
    let detailsBefore = getPositionDetails(pid: pid, beFailed: false)
    var collBefore: UFix64 = 0.0
    var debtBefore: UFix64 = 0.0
    let cbOpt = findBalance(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())
    if cbOpt != nil { collBefore = cbOpt! }
    let dbOpt = findBalance(details: detailsBefore, vaultType: Type<@MOET.Vault>())
    if dbOpt != nil { debtBefore = dbOpt! }
    log("MIRROR:coll_before=".concat(formatValue(collBefore)))
    log("MIRROR:debt_before=".concat(formatValue(debtBefore)))

    // Apply a flash crash to FLOW (e.g., -30%) akin to simulation stress
    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowType, price: 0.7)

    // Health at crash (pre-liquidation)
    let hfMin = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_min=".concat(formatHF(hfMin)))

    // Set liquidation target HF to 1.01 (reachable from 0.805)
    let liqParamsTx = Test.Transaction(
        code: Test.readFile("../transactions/tidal-protocol/pool-governance/set_liquidation_params.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [1.01, nil, nil]
    )
    let liqParamsRes = Test.executeTransaction(liqParamsTx)
    Test.expect(liqParamsRes, Test.beSucceeded())

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

    // Check liquidation quote first
    let quoteRes = _executeScript(
        "../../lib/TidalProtocol/cadence/scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>()]
    )
    
    // Only proceed with liquidation if quote is non-zero
    if quoteRes.status == Test.ResultStatus.succeeded {
        // Execute liquidation via mock dex when undercollateralized
        let liqTx = _executeTransaction(
            "../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc",
            [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.42857143],
            protocol
        )
        Test.expect(liqTx, Test.beSucceeded())
    }

    // Post-liquidation health should recover above 1.0 (tolerance window)
    let h = getPositionHealth(pid: pid, beFailed: false)
    log("MIRROR:hf_after=".concat(formatHF(h)))

    // Emit post-liquidation collateral and debt to confirm scale
    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    var collAfter: UFix64 = 0.0
    var debtAfter: UFix64 = 0.0
    let caOpt = findBalance(details: detailsAfter, vaultType: Type<@FlowToken.Vault>())
    if caOpt != nil { collAfter = caOpt! }
    let daOpt = findBalance(details: detailsAfter, vaultType: Type<@MOET.Vault>())
    if daOpt != nil { debtAfter = daOpt! }
    log("MIRROR:coll_after=".concat(formatValue(collAfter)))
    log("MIRROR:debt_after=".concat(formatValue(debtAfter)))

    // Emit liquidation metrics from events
    let liqEvents = Test.eventsOfType(Type<TidalProtocol.LiquidationExecutedViaDex>())
    let liqCount = liqEvents.length
    log("MIRROR:liq_count=".concat(liqCount.toString()))
    if liqCount > 0 {
        let last = liqEvents[liqCount - 1] as! TidalProtocol.LiquidationExecutedViaDex
        log("MIRROR:liq_repaid=".concat(formatValue(last.repaid)))
        log("MIRROR:liq_seized=".concat(formatValue(last.seized)))
    }
    let target = 1.01 as UFix128
    let tol = 0.01 as UFix128
    Test.assert(h >= target - tol)
}


