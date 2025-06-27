import Test
import "MOET"
import "TidalProtocol"
import "FlowToken"

import "./test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)

access(all) fun setup() {
    deployContracts()
    
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

access(all) fun testConcurrentRebalancing() {
    logSeparator(title: "CONCURRENT REBALANCING TEST")
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0, tokenName: "FLOW")
    setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@MOET.Vault>().identifier, price: 1.0, tokenName: "MOET")
    
    log("Creating position with 1000 FLOW...")
    let txRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1_000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(txRes, Test.beSucceeded())
    
    let initialHealth = getPositionHealth(pid: 0, beFailed: false)
    log("Initial health: ".concat(initialHealth.toString()))
    
    logSeparator(title: "Rapid price changes and rebalancing")
    
    // Simulate rapid price changes and rebalancing in the same block
    let prices: [UFix64] = [0.8, 1.2, 0.9, 1.1, 0.7, 1.3]
    var i = 0
    
    for price in prices {
        log("")
        log("Quick change #".concat(i.toString()).concat(": FLOW = ".concat(price.toString())))
        
        setMockOraclePriceWithLog(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: price, tokenName: "FLOW")
        
        let healthBefore = getPositionHealth(pid: 0, beFailed: false)
        log("Health: ".concat(healthBefore.toString()))
        
        // Try to rebalance multiple times quickly
        if i % 2 == 0 {
            log("Double rebalance attempt...")
            rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
            let midHealth = getPositionHealth(pid: 0, beFailed: false)
            log("Health after 1st rebalance: ".concat(midHealth.toString()))
            
            rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
            let finalHealth = getPositionHealth(pid: 0, beFailed: false)
            log("Health after 2nd rebalance: ".concat(finalHealth.toString()))
        } else {
            rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)
            let health = getPositionHealth(pid: 0, beFailed: false)
            log("Health after rebalance: ".concat(health.toString()))
        }
        
        i = i + 1
    }
    
    logSeparator(title: "Final State")
    logPositionDetails(pid: 0, stage: "After rapid changes")
    
    // Check final state
    log("Checking final position state...")
    let finalHealth = getPositionHealth(pid: 0, beFailed: false)
    log("Final health: ".concat(finalHealth.toString()))
}
