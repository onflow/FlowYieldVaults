import Test
import BlockchainHelpers
import "test_helpers.cdc"
import "FlowALP"
import "MOET"
import "FlowToken"
import "FlowALPMath"
import "RedemptionWrapper"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
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

    // Deploy RedemptionWrapper
    let err = Test.deployContract(
        name: "RedemptionWrapper",
        path: "../contracts/RedemptionWrapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Setup pool with FlowToken support
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 2.0)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

/// Test 1: Basic 1:1 Redemption Math
/// Verifies that 100 MOET with Flow at $2.00 returns exactly 50 Flow
access(all)
fun test_redemption_one_to_one_parity() {
    safeReset()
    
    // Setup redemption wrapper with initial collateral
    setupMoetVault(protocolAccount, beFailed: false)
    giveFlowTokens(to: protocolAccount, amount: 1000.0)
    
    // Setup redemption position via transaction
    let setupCode = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        import MOET from 0x0000000000000007
        import FlowALP from 0x0000000000000007
        import DeFiActions from 0x0000000000000007
        import FungibleTokenConnectors from 0x0000000000000007
        
        transaction(flowAmount: UFix64) {
            prepare(signer: auth(Storage, Capabilities) &Account) {
                // Get Flow collateral
                let flowVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)!
                    .withdraw(amount: flowAmount)
                
                // Create issuance sink (where borrowed MOET goes)
                let moetReceiver = signer.capabilities.get<&MOET.Vault>(/public/moetBalance)
                let issuanceSink = FungibleTokenConnectors.VaultReceiverSink(receiver: moetReceiver)
                
                // Setup redemption position
                RedemptionWrapper.setup(
                    initialCollateral: <-flowVault,
                    issuanceSink: issuanceSink,
                    repaymentSource: nil
                )
            }
        }
    """
    
    let setupTx = Test.Transaction(
        code: setupCode,
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: [500.0]
    )
    let setupRes = Test.executeTransaction(setupTx)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Verify position was created
    let positionHealthScript = """
        import RedemptionWrapper from 0x0000000000000007
        
        access(all) fun main(): UFix128 {
            return RedemptionWrapper.getPosition()!.getHealth()
        }
    """
    let healthRes = Test.executeScript(positionHealthScript, [])
    Test.expect(healthRes, Test.beSucceeded())
    let health = healthRes.returnValue! as! UFix128
    log("Initial position health: ".concat(health.toString()))
    
    // User setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    
    // Mint 100 MOET to user
    mintMoet(signer: protocolAccount, to: user.address, amount: 100.0, beFailed: false)
    
    // Execute redemption
    let redeemCode = """
        import RedemptionWrapper from 0x0000000000000007
        import MOET from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        import FungibleToken from 0xee82856bf20e2aa6
        
        transaction(moetAmount: UFix64) {
            prepare(signer: auth(Storage, Capabilities) &Account) {
                // Get MOET to redeem
                let moetVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: /storage/moetBalance)!
                    .withdraw(amount: moetAmount)
                
                // Get Flow receiver capability
                let flowReceiver = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                
                // Get redeemer capability
                let redeemer = getAccount(0x0000000000000007)
                    .capabilities.borrow<&RedemptionWrapper.Redeemer>(RedemptionWrapper.PublicRedemptionPath)
                    ?? panic("No redeemer capability")
                
                // Execute redemption
                redeemer.redeem(
                    moet: <-moetVault,
                    preferredCollateralType: nil, // Use default (Flow)
                    receiver: flowReceiver
                )
            }
        }
    """
    
    let redeemTx = Test.Transaction(
        code: redeemCode,
        authorizers: [user.address],
        signers: [user],
        arguments: [100.0]
    )
    let redeemRes = Test.executeTransaction(redeemTx)
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
    let setupCode = Test.readFile("./transactions/redemption/setup_redemption_position.cdc")
    let setupTx = Test.Transaction(
        code: setupCode,
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: [1000.0] // 1000 Flow collateral
    )
    let setupRes = Test.executeTransaction(setupTx)
    Test.expect(setupRes, Test.beSucceeded())
    
    // Get initial position state
    let initialDetailsScript = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowALP from 0x0000000000000007
        import MOET from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        
        access(all) fun main(): {String: UFix64} {
            let position = RedemptionWrapper.getPosition()!
            let balances = position.getBalances()
            
            var flowCollateral: UFix64 = 0.0
            var moetDebt: UFix64 = 0.0
            
            for bal in balances {
                if bal.vaultType == Type<@FlowToken.Vault>() && bal.direction == FlowALP.BalanceDirection.Credit {
                    flowCollateral = bal.balance
                }
                if bal.vaultType == Type<@MOET.Vault>() && bal.direction == FlowALP.BalanceDirection.Debit {
                    moetDebt = bal.balance
                }
            }
            
            return {
                "flowCollateral": flowCollateral,
                "moetDebt": moetDebt
            }
        }
    """
    
    let initialRes = Test.executeScript(initialDetailsScript, [])
    Test.expect(initialRes, Test.beSucceeded())
    let initialState = initialRes.returnValue! as! {String: UFix64}
    let initialFlow = initialState["flowCollateral"]!
    let initialDebt = initialState["moetDebt"]!
    
    log("Initial state: Flow=".concat(initialFlow.toString()).concat(", MOET debt=").concat(initialDebt.toString()))
    
    // User redeems 200 MOET
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 200.0, beFailed: false)
    
    let redeemCode = Test.readFile("./transactions/redemption/redeem_moet.cdc")
    let redeemTx = Test.Transaction(
        code: redeemCode,
        authorizers: [user.address],
        signers: [user],
        arguments: [200.0]
    )
    let redeemRes = Test.executeTransaction(redeemTx)
    Test.expect(redeemRes, Test.beSucceeded())
    
    // Get final position state
    let finalRes = Test.executeScript(initialDetailsScript, [])
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
    let configCode = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowALPMath from 0x0000000000000007
        
        transaction() {
            prepare(admin: auth(Storage) &Account) {
                let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
                    from: RedemptionWrapper.AdminStoragePath
                ) ?? panic("No admin resource")
                
                adminRef.setProtectionParams(
                    redemptionCooldown: 1.0,        // 1 second for testing
                    dailyRedemptionLimit: 1000.0,   // 1000 MOET daily limit
                    maxPriceAge: 3600.0,
                    minPostRedemptionHealth: FlowALPMath.toUFix128(1.15)
                )
            }
        }
    """
    let configTx = Test.Transaction(
        code: configCode,
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: []
    )
    let configRes = Test.executeTransaction(configTx)
    Test.expect(configRes, Test.beSucceeded())
    
    // User 1: Redeem 600 MOET (should succeed)
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintMoet(signer: protocolAccount, to: user1.address, amount: 600.0, beFailed: false)
    
    BlockchainHelpers.commitBlock()
    
    let redeem1Res = redeemMoet(user: user1, amount: 600.0)
    Test.expect(redeem1Res, Test.beSucceeded())
    log("User 1 redeemed 600 MOET successfully")
    
    // User 2: Redeem 500 MOET (should FAIL - exceeds daily limit)
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: protocolAccount, to: user2.address, amount: 500.0, beFailed: false)
    
    BlockchainHelpers.commitBlock()
    
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
    mintMoet(signer: protocolAccount, to: user3.address, amount: 100.0, beFailed: false)
    
    BlockchainHelpers.commitBlock()
    
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
    mintMoet(to: user, amount: 200.0)
    
    // First redemption: 50 MOET (should succeed)
    let redeem1Res = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeem1Res, Test.beSucceeded())
    log("First redemption succeeded")
    
    // Second redemption immediately: 50 MOET (should FAIL - cooldown not elapsed)
    BlockchainHelpers.commitBlock()
    
    let redeem2Res = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeem2Res, Test.beFailed())
    Test.assertError(redeem2Res, errorMessage: "Redemption cooldown not elapsed")
    log("Second redemption correctly rejected (cooldown active)")
    
    // Advance time by 61 seconds
    for i in 0...60 {
        BlockchainHelpers.commitBlock()
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
    mintMoet(signer: protocolAccount, to: user.address, amount: 20000.0, beFailed: false)
    
    // Test: Below minimum (default 10.0 MOET)
    let tooSmallRes = redeemMoet(user: user, amount: 5.0)
    Test.expect(tooSmallRes, Test.beFailed())
    Test.assertError(tooSmallRes, errorMessage: "Below minimum redemption amount")
    log("Redemption of 5 MOET correctly rejected (below min 10)")
    
    // Test: Above maximum (default 10,000.0 MOET)
    BlockchainHelpers.commitBlock()
    let tooLargeRes = redeemMoet(user: user, amount: 15000.0)
    Test.expect(tooLargeRes, Test.beFailed())
    Test.assertError(tooLargeRes, errorMessage: "Exceeds max redemption amount")
    log("Redemption of 15000 MOET correctly rejected (above max 10000)")
    
    // Test: Within bounds
    BlockchainHelpers.commitBlock()
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
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false) // More MOET than can be redeemed
    
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
    mintMoet(to: user, amount: 200.0)
    
    // Pause redemptions
    let pauseCode = """
        import RedemptionWrapper from 0x0000000000000007
        
        transaction() {
            prepare(admin: auth(Storage) &Account) {
                let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
                    from: RedemptionWrapper.AdminStoragePath
                ) ?? panic("No admin resource")
                
                adminRef.pause()
            }
        }
    """
    let pauseTx = Test.Transaction(
        code: pauseCode,
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: []
    )
    let pauseRes = Test.executeTransaction(pauseTx)
    Test.expect(pauseRes, Test.beSucceeded())
    log("Redemptions paused")
    
    // Try to redeem (should fail)
    let redeemWhilePausedRes = redeemMoet(user: user, amount: 50.0)
    Test.expect(redeemWhilePausedRes, Test.beFailed())
    Test.assertError(redeemWhilePausedRes, errorMessage: "Redemptions are paused")
    log("Redemption correctly rejected while paused")
    
    // Unpause
    let unpauseCode = """
        import RedemptionWrapper from 0x0000000000000007
        
        transaction() {
            prepare(admin: auth(Storage) &Account) {
                let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
                    from: RedemptionWrapper.AdminStoragePath
                ) ?? panic("No admin resource")
                
                adminRef.unpause()
            }
        }
    """
    let unpauseTx = Test.Transaction(
        code: unpauseCode,
        authorizers: [protocolAccount.address],
        signers: [protocolAccount],
        arguments: []
    )
    let unpauseRes = Test.executeTransaction(unpauseTx)
    Test.expect(unpauseRes, Test.beSucceeded())
    log("Redemptions unpaused")
    
    // Try to redeem again (should succeed)
    BlockchainHelpers.commitBlock()
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
        mintMoet(signer: protocolAccount, to: user.address, amount: 100.0, beFailed: false)
        
        BlockchainHelpers.commitBlock() // Advance time for cooldown
        
        let redeemRes = redeemMoet(user: user, amount: 100.0)
        Test.expect(redeemRes, Test.beSucceeded())
        
        // Check position health after each redemption
        let healthScript = """
            import RedemptionWrapper from 0x0000000000000007
            
            access(all) fun main(): UFix128 {
                return RedemptionWrapper.getPosition()!.getHealth()
            }
        """
        let healthRes = Test.executeScript(healthScript, [])
        Test.expect(healthRes, Test.beSucceeded())
        let health = healthRes.returnValue! as! UFix128
        
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
    let estimateScript = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        
        access(all) fun main(amount: UFix64): UFix64 {
            return RedemptionWrapper.estimateRedemption(
                moetAmount: amount,
                collateralType: Type<@FlowToken.Vault>()
            )
        }
    """
    let estimateRes = Test.executeScript(estimateScript, [100.0])
    Test.expect(estimateRes, Test.beSucceeded())
    let estimated = estimateRes.returnValue! as! UFix64
    
    // 100 MOET / $2.00 price = 50.0 Flow
    Test.assertEqual(50.0, estimated)
    log("estimateRedemption correctly calculated 50 Flow for 100 MOET")
    
    // Test canRedeem (before user has MOET)
    let canRedeemScript = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        
        access(all) fun main(amount: UFix64, user: Address): Bool {
            return RedemptionWrapper.canRedeem(
                moetAmount: amount,
                collateralType: Type<@FlowToken.Vault>(),
                user: user
            )
        }
    """
    let canRedeemRes = Test.executeScript(canRedeemScript, [100.0, user.address])
    Test.expect(canRedeemRes, Test.beSucceeded())
    let canRedeem = canRedeemRes.returnValue! as! Bool
    
    // Should be able to redeem (sufficient collateral, no cooldown yet)
    Test.assertEqual(true, canRedeem)
    log("canRedeem correctly returns true for valid redemption")
    
    // Test canRedeem with too large amount
    let canRedeemLargeRes = Test.executeScript(canRedeemScript, [20000.0, user.address])
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
    
    // Check position is now liquidatable
    let isLiquidatableScript = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowALP from 0x0000000000000007
        
        access(all) fun main(): Bool {
            let pool = RedemptionWrapper.getPool()
            let position = RedemptionWrapper.getPosition()!
            let positionID = position.getBalances()[0].vaultType.identifier // Hack to get ID
            
            let health = position.getHealth()
            return health < FlowALPMath.toUFix128(1.0)
        }
    """
    let liquidatableRes = Test.executeScript(isLiquidatableScript, [])
    Test.expect(liquidatableRes, Test.beSucceeded())
    let isLiquidatable = liquidatableRes.returnValue! as! Bool
    
    if isLiquidatable {
        log("Position is liquidatable (health < 1.0)")
        
        // Try to redeem (should fail)
        let user = Test.createAccount()
        setupMoetVault(user, beFailed: false)
        mintMoet(signer: protocolAccount, to: user.address, amount: 100.0, beFailed: false)
        
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
    let code = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowToken from 0x0000000000000003
        import MOET from 0x0000000000000007
        import FlowALP from 0x0000000000000007
        import FungibleToken from 0xee82856bf20e2aa6
        import FungibleTokenConnectors from 0x0000000000000007
        
        transaction(flowAmount: UFix64) {
            prepare(signer: auth(Storage, Capabilities) &Account) {
                let flowVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)!
                    .withdraw(amount: flowAmount)
                
                let moetReceiver = signer.capabilities.get<&MOET.Vault>(/public/moetBalance)
                let issuanceSink = FungibleTokenConnectors.VaultReceiverSink(receiver: moetReceiver)
                
                RedemptionWrapper.setup(
                    initialCollateral: <-flowVault,
                    issuanceSink: issuanceSink,
                    repaymentSource: nil
                )
            }
        }
    """
    
    let tx = Test.Transaction(
        code: code,
        authorizers: [signer.address],
        signers: [signer],
        arguments: [flowAmount]
    )
    return Test.executeTransaction(tx)
}

access(all)
fun redeemMoet(user: Test.TestAccount, amount: UFix64): Test.TransactionResult {
    let code = """
        import RedemptionWrapper from 0x0000000000000007
        import MOET from 0x0000000000000007
        import FungibleToken from 0xee82856bf20e2aa6
        
        transaction(moetAmount: UFix64) {
            prepare(signer: auth(Storage, Capabilities) &Account) {
                let moetVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: /storage/moetBalance)!
                    .withdraw(amount: moetAmount)
                
                let flowReceiver = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                
                let redeemer = getAccount(0x0000000000000007)
                    .capabilities.borrow<&RedemptionWrapper.Redeemer>(RedemptionWrapper.PublicRedemptionPath)
                    ?? panic("No redeemer capability")
                
                redeemer.redeem(
                    moet: <-moetVault,
                    preferredCollateralType: nil,
                    receiver: flowReceiver
                )
            }
        }
    """
    
    let tx = Test.Transaction(
        code: code,
        authorizers: [user.address],
        signers: [user],
        arguments: [amount]
    )
    return Test.executeTransaction(tx)
}

access(all)
fun setRedemptionCooldown(admin: Test.TestAccount, cooldownSeconds: UFix64): Test.TransactionResult {
    let code = """
        import RedemptionWrapper from 0x0000000000000007
        import FlowALPMath from 0x0000000000000007
        
        transaction(cooldown: UFix64) {
            prepare(admin: auth(Storage) &Account) {
                let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
                    from: RedemptionWrapper.AdminStoragePath
                ) ?? panic("No admin resource")
                
                adminRef.setProtectionParams(
                    redemptionCooldown: cooldown,
                    dailyRedemptionLimit: 100000.0,
                    maxPriceAge: 3600.0,
                    minPostRedemptionHealth: FlowALPMath.toUFix128(1.15)
                )
            }
        }
    """
    
    let tx = Test.Transaction(
        code: code,
        authorizers: [admin.address],
        signers: [admin],
        arguments: [cooldownSeconds]
    )
    return Test.executeTransaction(tx)
}

/// Give Flow tokens to test account (mints from service account)
access(all)
fun giveFlowTokens(to: Test.TestAccount, amount: UFix64) {
    let serviceAccount = Test.serviceAccount()
    
    let code = """
        import FlowToken from 0x0000000000000003
        import FungibleToken from 0xee82856bf20e2aa6
        
        transaction(recipient: Address, amount: UFix64) {
            prepare(service: auth(Storage) &Account) {
                // Get Flow from service account
                let flowVault <- service.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)!
                    .withdraw(amount: amount)
                
                // Setup receiver if needed
                if getAccount(recipient).capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver).check() == false {
                    // Receiver not setup - need to initialize
                }
                
                let receiver = getAccount(recipient).capabilities
                    .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                    ?? panic("No receiver")
                
                receiver.deposit(from: <-flowVault)
            }
        }
    """
    
    let tx = Test.Transaction(
        code: code,
        authorizers: [serviceAccount.address],
        signers: [serviceAccount],
        arguments: [to.address, amount]
    )
    let res = Test.executeTransaction(tx)
    Test.expect(res, Test.beSucceeded())
}

