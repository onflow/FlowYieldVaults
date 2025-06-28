import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"

import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)

access(all) fun setup() {
    deployContracts()
    
    // Setup pool and supported tokens
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: Type<@FlowToken.Vault>().identifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
}

access(all) fun testMOETDepegScenario() {
    logSeparator(title: "MOET DEPEG SCENARIO TEST")
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    
    // Initial setup - FLOW and MOET both at 1.0
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0, tokenName: "FLOW")
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 1.0, tokenName: "MOET")
    
    log("Creating position with 1000 FLOW...")
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(txRes, Test.beSucceeded())
    
    logSeparator(title: "Stage 1: MOET loses peg - drops to 0.5")
    
    // MOET depegs to 0.5 (while FLOW stays at 1.0)
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 0.5, tokenName: "MOET")
    
    let healthBefore1 = getPositionHealth(pid: 0, beFailed: false)
    log("Health before rebalance: ".concat(healthBefore1.toString()))
    
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
    
    let healthAfter1 = getPositionHealth(pid: 0, beFailed: false)
    log("Health after rebalance: ".concat(healthAfter1.toString()))
    log("OBSERVATION: When MOET depegs, the position health should improve because debt is denominated in MOET")
    
    logSeparator(title: "Stage 2: FLOW also drops to 0.5")
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 0.5, tokenName: "FLOW")
    
    let healthBefore2 = getPositionHealth(pid: 0, beFailed: false)
    log("Health before rebalance: ".concat(healthBefore2.toString()))
    
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
    
    let healthAfter2 = getPositionHealth(pid: 0, beFailed: false)  
    log("Health after rebalance: ".concat(healthAfter2.toString()))
    log("OBSERVATION: With both tokens at 0.5, position should be similar to original state")
    
    logSeparator(title: "Stage 3: MOET crashes to 0.1 while FLOW stays at 0.5")
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 0.1, tokenName: "MOET")
    
    let healthBefore3 = getPositionHealth(pid: 0, beFailed: false)
    log("Health before rebalance: ".concat(healthBefore3.toString()))
    log("OBSERVATION: Extreme MOET crash should make debt very cheap, improving health dramatically")
    
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
    
    let healthAfter3 = getPositionHealth(pid: 0, beFailed: false)
    log("Health after rebalance: ".concat(healthAfter3.toString()))
    
    logComprehensivePositionState(pid: 0, stage: "After extreme MOET depeg", flowPrice: 0.5, moetPrice: 0.1)
}
