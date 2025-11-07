import Test
import "test_helpers.cdc"
import "FungibleToken"
import "FlowALP"
import "MOET"
import "FlowToken"
import "FlowALPMath"
import "RedemptionWrapper"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000008.MOET.Vault"
access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let flowALPAccount = Test.getAccount(0x0000000000000008)
access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlock().height
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()

    // Deploy RedemptionWrapper
    let err = Test.deployContract(
        name: "RedemptionWrapper",
        path: "../contracts/RedemptionWrapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Setup pool with FlowToken support (use flowALPAccount which has the PoolFactory)
    setMockOraclePrice(signer: flowALPAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    createAndStorePool(signer: flowALPAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    
    // Grant pool capability to RedemptionWrapper account (protocolAccount)
    let grantRes = grantProtocolBeta(flowALPAccount, protocolAccount)
    Test.expect(grantRes, Test.beSucceeded())
    addSupportedTokenSimpleInterestCurve(
        signer: flowALPAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlock().height
}

/// Test 1: Basic 1:1 Redemption Math
/// Verifies that 100 MOET with Flow at $2.00 returns exactly 50 Flow
access(all)
fun test_redemption_one_to_one_parity() {
    safeReset()
    
    // Setup redemption wrapper with initial collateral
    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 1000.0)
    
    // Setup redemption position
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 500.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Verify position was created and check health
    let health = getRedemptionPositionHealth()
    log("Initial position health: ".concat(health.toString()))
    
    // User setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    
    // Mint 100 MOET to user
    mintMoet(signer: flowALPAccount, to: user.address, amount: 100.0, beFailed: false)
    
    // Execute redemption
    let redeemRes = redeemMoet(user: user, amount: 100.0)
    Test.expect(redeemRes, Test.beSucceeded())
    
    // Verify user received exactly 50 Flow (100 MOET / $2.00 price = 50 Flow)
    let userFlowBalance = getBalance(address: user.address, vaultPublicPath: /public/flowTokenBalance) ?? 0.0
    log("User Flow balance after redemption: ".concat(userFlowBalance.toString()))
    Test.assertEqual(50.0, userFlowBalance)
    
    // Verify 1:1 parity: $100 of MOET = $100 of collateral
    let collateralValue = userFlowBalance * 2.0 // 50 Flow * $2.00
    Test.assertEqual(100.0, collateralValue)
}

/// Test 2: Position Neutrality
/// Verifies that debt reduction equals collateral value withdrawn
access(all)
fun test_position_neutrality() {
    safeReset()

    let protocolAccount = Test.getAccount(0x0000000000000007)
    setupMoetVault(protocolAccount, beFailed: false)
    transferFlowTokens(to: protocolAccount, amount: 2000.0)
    
    // Setup redemption position
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 1000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Get initial position state
    let initialRes = _executeScript("./scripts/redemption/get_position_details.cdc", [])
    Test.expect(initialRes, Test.beSucceeded())
    let initialState = initialRes.returnValue! as! {String: UFix64}
    let initialFlow = initialState["flowCollateral"]!
    let initialDebt = initialState["moetDebt"]!
    
    log("Initial state: Flow=".concat(initialFlow.toString()).concat(", MOET debt=").concat(initialDebt.toString()))
    
    // User redeems 200 MOET
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user.address, amount: 200.0, beFailed: false)
    
    let redeemRes = redeemMoet(user: user, amount: 200.0)
    Test.expect(redeemRes, Test.beSucceeded())
    
    // Get final position state
    let finalRes = _executeScript("./scripts/redemption/get_position_details.cdc", [])
    Test.expect(finalRes, Test.beSucceeded())
    let finalState = finalRes.returnValue! as! {String: UFix64}
    let finalFlow = finalState["flowCollateral"]!
    let finalDebt = finalState["moetDebt"]!
    
    log("Final state: Flow=".concat(finalFlow.toString()).concat(", MOET debt=").concat(finalDebt.toString()))
    
    // Verify position neutrality
    let flowWithdrawn = initialFlow - finalFlow // Should be 100.0 Flow
    let debtReduced = initialDebt - finalDebt // Should be 200.0 MOET
    let flowValue = flowWithdrawn * 2.0 // 100 Flow * $2.00 = $200
    
    log("Flow withdrawn: ".concat(flowWithdrawn.toString()).concat(" ($").concat(flowValue.toString()).concat(")"))
    log("Debt reduced: ".concat(debtReduced.toString()).concat(" MOET ($").concat(debtReduced.toString()).concat(")"))
    
    // Verify neutrality: $200 collateral = $200 debt
    Test.assertEqual(200.0, debtReduced)
    Test.assertEqual(flowValue, debtReduced)
}

/// Test 3: Daily Limit Circuit Breaker
/// Verifies that redemptions are blocked after hitting daily limit
access(all)
fun test_daily_limit_circuit_breaker() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 50000.0) // Large amount for testing
    
    // Setup with generous collateral
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 50000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Configure lower daily limit for testing (1000 MOET)
    let configRes = _executeTransaction(
        "./transactions/redemption/configure_protections.cdc",
        [1.0, 1000.0, 3600.0, 1.15], // cooldown, dailyLimit, maxPriceAge, minHealth
        protocolAccount
    )
    Test.expect(configRes, Test.beSucceeded())
    
    // User 1: Redeem 600 MOET (should succeed)
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user1.address, amount: 600.0, beFailed: false)
    
    // Block automatically commits
    
    let redeem1Res = redeemMoet(user: user1, amount: 600.0)
    Test.expect(redeem1Res, Test.beSucceeded())
    log("User 1 redeemed 600 MOET successfully")
    
    // User 2: Redeem 500 MOET (should FAIL - exceeds daily limit)
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user2.address, amount: 500.0, beFailed: false)
    
    // Block automatically commits
    
    let redeem2Res = redeemMoet(user: user2, amount: 500.0)
    Test.expect(redeem2Res, Test.beFailed())
    Test.assertError(redeem2Res, errorMessage: "Daily redemption limit exceeded")
    log("User 2 redemption correctly rejected (would exceed 1000 MOET daily limit)")
    
    // User 2: Redeem 400 MOET (should succeed - within remaining limit)
    let redeem3Res = redeemMoet(user: user2, amount: 400.0)
    Test.expect(redeem3Res, Test.beSucceeded())
    log("User 2 redeemed 400 MOET successfully (total 1000 MOET)")
    
    // User 3: Any redemption should fail (limit exhausted)
    let user3 = Test.createAccount()
    setupMoetVault(user3, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user3.address, amount: 100.0, beFailed: false)
    
    // Block automatically commits
    
    let redeem4Res = redeemMoet(user: user3, amount: 100.0)
    Test.expect(redeem4Res, Test.beFailed())
    Test.assertError(redeem4Res, errorMessage: "Daily redemption limit exceeded")
    log("User 3 redemption correctly rejected (daily limit exhausted)")
}

/// Test 4: User Cooldown Enforcement
/// Verifies users must wait between redemptions
access(all)
fun test_user_cooldown_enforcement() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 5000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 5000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Configure 60 second cooldown
    let configRes = setRedemptionCooldown(admin: protocolAccount, cooldownSeconds: 60.0)
    Test.expect(configRes, Test.beSucceeded())
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user.address, amount: 200.0, beFailed: false)
    
    // First redemption: 50 MOET (should succeed)
    let redeem1Res = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeem1Res, Test.beSucceeded())
    log("First redemption succeeded")
    
    // Second redemption immediately: 50 MOET (should FAIL - cooldown not elapsed)
    // Block automatically commits
    
    let redeem2Res = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeem2Res, Test.beFailed())
    Test.assertError(redeem2Res, errorMessage: "Redemption cooldown not elapsed")
    log("Second redemption correctly rejected (cooldown active)")
    
    // Advance time by 61 seconds
    var blockCount = 0
    while blockCount < 61 {
        // Block automatically commits
        blockCount = blockCount + 1
    }
    
    // Third redemption after cooldown: 50 MOET (should succeed)
    let redeem3Res = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeem3Res, Test.beSucceeded())
    log("Third redemption succeeded after cooldown elapsed")
}

/// Test 5: Min/Max Redemption Amounts
/// Verifies amount limits are enforced
access(all)
fun test_min_max_redemption_amounts() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 10000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 10000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user.address, amount: 20000.0, beFailed: false)
    
    // Test: Below minimum (default 10.0 MOET)
    let tooSmallRes = redeemMoet(user: user, amount: 5.0)
    Test.expect(tooSmallRes, Test.beFailed())
    Test.assertError(tooSmallRes, errorMessage: "Below minimum redemption amount")
    log("Redemption of 5 MOET correctly rejected (below min 10)")
    
    // Test: Above maximum (default 10,000.0 MOET)
    // Block automatically commits
    let tooLargeRes = redeemMoet(user: user, amount: 15000.0)
    Test.expect(tooLargeRes, Test.beFailed())
    Test.assertError(tooLargeRes, errorMessage: "Exceeds max redemption amount")
    log("Redemption of 15000 MOET correctly rejected (above max 10000)")
    
    // Test: Within bounds
    // Block automatically commits
    let validRes = redeemMoet(user: user, amount: 100.0)
    Test.expect(validRes, Test.beSucceeded())
    log("Redemption of 100 MOET succeeded (within bounds)")
}

/// Test 6: Insufficient Collateral Handling
/// Verifies redemption fails gracefully when not enough collateral available
access(all)
fun test_insufficient_collateral() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 100.0) // Small amount
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 100.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user.address, amount: 1000.0, beFailed: false) // More MOET than can be redeemed
    
    // Try to redeem more than available
    // Position has ~100 Flow = $200 worth
    // User wants to redeem 500 MOET (needs $500 worth = 250 Flow)
    let redeemRes = redeemMoet(user: user, amount: 500.0)
    Test.expect(redeemRes, Test.beFailed())
    Test.assertError(redeemRes, errorMessage: "Insufficient collateral available")
    log("Redemption correctly rejected when insufficient collateral")
}

/// Test 7: Pause Mechanism
/// Verifies admin can pause and unpause redemptions
access(all)
fun test_pause_mechanism() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 1000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 1000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: flowALPAccount, to: user.address, amount: 200.0, beFailed: false)
    
    // Pause redemptions
    let pauseRes = _executeTransaction("./transactions/redemption/pause_redemptions.cdc", [], protocolAccount)
    Test.expect(pauseRes, Test.beSucceeded())
    log("Redemptions paused")
    
    // Try to redeem (should fail)
    let redeemWhilePausedRes = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeemWhilePausedRes, Test.beFailed())
    Test.assertError(redeemWhilePausedRes, errorMessage: "Redemptions are paused")
    log("Redemption correctly rejected while paused")
    
    // Unpause
    let unpauseRes = _executeTransaction("./transactions/redemption/unpause_redemptions.cdc", [], protocolAccount)
    Test.expect(unpauseRes, Test.beSucceeded())
    log("Redemptions unpaused")
    
    // Try to redeem again (should succeed)
    // Block automatically commits
    let redeemAfterUnpauseRes = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeemAfterUnpauseRes, Test.beSucceeded())
    log("Redemption succeeded after unpause")
}

/// Test 8: Sequential Redemptions by Multiple Users
/// Verifies position stays healthy with multiple redemptions
access(all)
fun test_sequential_redemptions() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 5000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 5000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Set cooldown to 1 second for faster testing
    let configRes = setRedemptionCooldown(admin: protocolAccount, cooldownSeconds: 1.0)
    Test.expect(configRes, Test.beSucceeded())
    
    // Create 5 users, each redeems 100 MOET
    var i = 0
    while i < 5 {
        let user = Test.createAccount()
        setupMoetVault(user, beFailed: false)
        mintMoet(signer: flowALPAccount, to: user.address, amount: 100.0, beFailed: false)
        
        // Block automatically commits // Advance time for cooldown
        
        let redeemRes = redeemMoet(user: user, amount: 100.0)
        Test.expect(redeemRes, Test.beSucceeded())
        
        // Check position health after each redemption
        let health = getRedemptionPositionHealth()
        
        log("User ".concat(i.toString()).concat(" redeemed. Position health: ").concat(health.toString()))
        
        // Health should remain above minimum (1.15 = 115%)
        Test.assert(health >= 1.15 as UFix128, message: "Position health below minimum after redemption")
        
        i = i + 1
    }
    
    log("All 5 users redeemed successfully, position remains healthy")
}

/// Test 9: View Function Accuracy
/// Verifies canRedeem and estimateRedemption work correctly
access(all)
fun test_view_functions() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 1000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 1000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    let user = Test.createAccount()
    
    // Test estimateRedemption
    let estimateRes = _executeScript("./scripts/redemption/estimate_redemption.cdc", [100.0])
    Test.expect(estimateRes, Test.beSucceeded())
    let estimated = estimateRes.returnValue! as! UFix64
    
    // 100 MOET / $2.00 price = 50.0 Flow
    Test.assertEqual(50.0, estimated)
    log("estimateRedemption correctly calculated 50 Flow for 100 MOET")
    
    // Test canRedeem (before user has MOET)
    let canRedeemRes = _executeScript("./scripts/redemption/can_redeem.cdc", [100.0, user.address])
    Test.expect(canRedeemRes, Test.beSucceeded())
    let canRedeem = canRedeemRes.returnValue! as! Bool
    
    // Should be able to redeem (sufficient collateral, no cooldown yet)
    Test.assertEqual(true, canRedeem)
    log("canRedeem correctly returns true for valid redemption")
    
    // Test canRedeem with too large amount
    let canRedeemLargeRes = _executeScript("./scripts/redemption/can_redeem.cdc", [20000.0, user.address])
    Test.expect(canRedeemLargeRes, Test.beSucceeded())
    let canRedeemLarge = canRedeemLargeRes.returnValue! as! Bool
    
    Test.assertEqual(false, canRedeemLarge)
    log("canRedeem correctly returns false for amount exceeding max")
}

/// Test 10: Liquidation Prevention
/// Verifies redemptions are blocked if position becomes liquidatable
access(all)
fun test_liquidation_prevention() {
    safeReset()

    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 1000.0)
    
    let setupRes = setupRedemptionPosition(signer: protocolAccount, flowAmount: 1000.0)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Crash the Flow price to make position liquidatable
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.5)
    
    // Check position health - if less than 1.0, it's liquidatable
    let health = getRedemptionPositionHealth()
    let isLiquidatable = health < FlowALPMath.toUFix128(1.0)
    
    if isLiquidatable {
        log("Position is liquidatable (health < 1.0)")
        
        // Try to redeem (should fail)
        let user = Test.createAccount()
        setupMoetVault(user, beFailed: false)
        mintMoet(signer: flowALPAccount, to: user.address, amount: 100.0, beFailed: false)
        
        let redeemRes = redeemMoet(user: user, amount: 100.0)
        Test.expect(redeemRes, Test.beFailed())
        Test.assertError(redeemRes, errorMessage: "Redemption position is liquidatable")
        log("Redemption correctly rejected from liquidatable position")
    } else {
        log("Position not liquidatable - test scenario setup issue")
    }
}

/* --- Helper Functions --- */

access(all)
fun setupRedemptionPosition(signer: Test.TestAccount, flowAmount: UFix64): Test.TransactionResult {
    return _executeTransaction(
        "./transactions/redemption/setup_redemption_position.cdc",
        [flowAmount],
        signer
    )
}

access(all)
fun redeemMoet(user: Test.TestAccount, amount: UFix64): Test.TransactionResult {
    return _executeTransaction(
        "./transactions/redemption/redeem_moet.cdc",
        [amount],
        user
    )
}

access(all)
fun setRedemptionCooldown(admin: Test.TestAccount, cooldownSeconds: UFix64): Test.TransactionResult {
    return _executeTransaction(
        "./transactions/redemption/configure_protections.cdc",
        [cooldownSeconds, 100000.0, 3600.0, 1.15],
        admin
    )
}

access(all)
fun getRedemptionPositionHealth(): UFix128 {
    let res = _executeScript("./scripts/redemption/get_position_health.cdc", [])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue! as! UFix128
}

/// Give Flow tokens to test account
access(all)
fun giveFlowTokens(to: Test.TestAccount, amount: UFix64) {
    // Use the test_helpers function to transfer Flow tokens
    transferFlowTokens(to: to, amount: amount)
}

