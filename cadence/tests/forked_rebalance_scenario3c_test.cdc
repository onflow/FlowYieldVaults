// Scenario 3C: Flow price increases 2x, Yield vault price increases 2x
// This height guarantees enough liquidity for the test
#test_fork(network: "mainnet", height: 140164761)

import Test
import BlockchainHelpers

import "test_helpers.cdc"

// FlowYieldVaults platform
import "FlowYieldVaults"
// other
import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV1_1"
import "FlowCreditMarket"
import "EVM"

import "DeFiActions"

// check (and update) flow.json for correct addresses
// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

// ============================================================================
// PROTOCOL ADDRESSES
// ============================================================================

// Uniswap V3 Factory on Flow EVM mainnet
access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// ============================================================================
// VAULT & TOKEN ADDRESSES
// ============================================================================

// FUSDEV - Morpho VaultV2 (ERC4626)
// Underlying asset: PYUSD0
access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"

// PYUSD0 - Stablecoin (FUSDEV's underlying asset)
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"

// MOET - Flow Omni Token
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"

// WFLOW - Wrapped Flow
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

// Token balanceOf mapping slots (for EVM.store to manipulate balances)
access(all) let moetBalanceSlot = 0 as UInt256        // MOET balanceOf at slot 0
access(all) let pyusd0BalanceSlot = 1 as UInt256     // PYUSD0 balanceOf at slot 1
access(all) let fusdevBalanceSlot = 12 as UInt256    // FUSDEV (Morpho VaultV2) balanceOf at slot 12
access(all) let wflowBalanceSlot = 1 as UInt256      // WFLOW balanceOf at slot 1

// Morpho vault storage slots
access(all) let morphoVaultTotalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"  // slot 15 (packed with lastUpdate and maxRate)

access(all)
fun setup() {
    // Deploy mock EVM contract to enable vm.store/vm.load cheatcodes
    var err = Test.deployContract(name: "EVM", path: "../contracts/mocks/EVM.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    
    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    setupUniswapPools(signer: coaOwnerAccount)

    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = { 
        "FLOW": 1.0,  // Start at 1.0, will increase to 2.0 during test
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)
    mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_ForkedRebalanceYieldVaultScenario3C() {
    let fundingAmount = 1000.0
    let flowPriceIncrease = 2.0
    let yieldPriceIncrease = 2.0

    // Expected values from Google sheet calculations
    let expectedYieldTokenValues = [615.38461539, 1230.76923077, 994.08284024]
    let expectedFlowCollateralValues = [1000.0, 2000.0, 3230.76923077]
    let expectedDebtValues = [615.38461539, 1230.76923077, 1988.16568047]

    let user = Test.createAccount()

    transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1 price
    setVaultSharePrice(vaultAddress: morphoVaultAddress, priceMultiplier: 1.0, signer: user)

    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    // Capture the actual position ID from the FlowCreditMarket.Opened event
    var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowCreditMarket.Opened>())) as! FlowCreditMarket.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueBefore = flowCollateralBefore * 1.0
    
    log("\n=== Initial State ===")
    log("Yield Tokens: \(yieldTokensBefore) (expected: \(expectedYieldTokenValues[0]))")
    log("Flow Collateral: \(flowCollateralBefore) FLOW")
    log("MOET Debt: \(debtBefore)")
    
    Test.assert(
        equalAmounts(a: yieldTokensBefore, b: expectedYieldTokenValues[0], tolerance: expectedYieldTokenValues[0] * forkedPercentTolerance),
        message: "Expected yield tokens to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueBefore, b: expectedFlowCollateralValues[0], tolerance: expectedFlowCollateralValues[0] * forkedPercentTolerance),
        message: "Expected flow collateral value to be \(expectedFlowCollateralValues[0]) but got \(flowCollateralValueBefore)"
    )
    Test.assert(
        equalAmounts(a: debtBefore, b: expectedDebtValues[0], tolerance: expectedDebtValues[0] * forkedPercentTolerance),
        message: "Expected MOET debt to be \(expectedDebtValues[0]) but got \(debtBefore)"
    )

    // === FLOW PRICE INCREASE TO 2.0 ===
    log("\n=== FLOW PRICE → 2.0x ===")
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPriceIncrease,
        "USD": 1.0
    })

    // Update PYUSD0/FLOW pool to match new Flow price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 2.0,  // Flow is 2x the price of PYUSD0
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterFlowPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterFlowIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterFlowIncrease = flowCollateralAfterFlowIncrease * flowPriceIncrease
    let debtAfterFlowIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== After Flow Price Increase ===")
    log("Yield Tokens: \(yieldTokensAfterFlowPriceIncrease) (expected: \(expectedYieldTokenValues[1]))")
    log("Flow Collateral: \(flowCollateralAfterFlowIncrease) FLOW (value: $\(flowCollateralValueAfterFlowIncrease))")
    log("MOET Debt: \(debtAfterFlowIncrease)")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterFlowPriceIncrease, b: expectedYieldTokenValues[1], tolerance: expectedYieldTokenValues[1] * forkedPercentTolerance),
        message: "Expected yield tokens after flow price increase to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceIncrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueAfterFlowIncrease, b: expectedFlowCollateralValues[1], tolerance: expectedFlowCollateralValues[1] * forkedPercentTolerance),
        message: "Expected flow collateral value after flow price increase to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowIncrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterFlowIncrease, b: expectedDebtValues[1], tolerance: expectedDebtValues[1] * forkedPercentTolerance),
        message: "Expected MOET debt after flow price increase to be \(expectedDebtValues[1]) but got \(debtAfterFlowIncrease)"
    )

    // === YIELD VAULT PRICE INCREASE TO 2.0 ===
    log("\n=== YIELD VAULT PRICE → 2.0x ===")
    
    setVaultSharePrice(vaultAddress: morphoVaultAddress, priceMultiplier: yieldPriceIncrease, signer: user)
    
    // Update FUSDEV pools to 2:1 price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    // Trigger the buggy rebalance
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceIncrease
    let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== After Yield Vault Price Increase ===")
    log("Yield Tokens: \(yieldTokensAfterYieldPriceIncrease) (expected: \(expectedYieldTokenValues[2]))")
    log("Flow Collateral: \(flowCollateralAfterYieldIncrease) FLOW (value: $\(flowCollateralValueAfterYieldIncrease))")
    log("MOET Debt: \(debtAfterYieldIncrease)")
    log("BUG: Should have WITHDRAWN to \(expectedYieldTokenValues[2]), but DEPOSITED instead!")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterYieldPriceIncrease, b: expectedYieldTokenValues[2], tolerance: expectedYieldTokenValues[2] * forkedPercentTolerance),
        message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueAfterYieldIncrease, b: expectedFlowCollateralValues[2], tolerance: expectedFlowCollateralValues[2] * forkedPercentTolerance),
        message: "Expected flow collateral value after yield price increase to be \(expectedFlowCollateralValues[2]) but got \(flowCollateralValueAfterYieldIncrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterYieldIncrease, b: expectedDebtValues[2], tolerance: expectedDebtValues[2] * forkedPercentTolerance),
        message: "Expected MOET debt after yield price increase to be \(expectedDebtValues[2]) but got \(debtAfterYieldIncrease)"
    )

    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
    
    log("\n=== TEST COMPLETE ===")
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================


// Setup Uniswap V3 pools with valid state at specified prices
access(all) fun setupUniswapPools(signer: Test.TestAccount) {
    log("\n=== Setting up Uniswap V3 pools ===")
    
    let fusdevDexPremium = 1.01
    
    let poolConfigs: [{String: AnyStruct}] = [
        {
            "name": "PYUSD0/FUSDEV",
            "tokenA": pyusd0Address,
            "tokenB": morphoVaultAddress,
            "fee": 100 as UInt64,
            "tokenABalanceSlot": pyusd0BalanceSlot,
            "tokenBBalanceSlot": fusdevBalanceSlot,
            "priceTokenBPerTokenA": fusdevDexPremium
        },
        {
            "name": "PYUSD0/FLOW",
            "tokenA": pyusd0Address,
            "tokenB": wflowAddress,
            "fee": 3000 as UInt64,
            "tokenABalanceSlot": pyusd0BalanceSlot,
            "tokenBBalanceSlot": wflowBalanceSlot,
            "priceTokenBPerTokenA": 1.0
        },
        {
            "name": "MOET/FUSDEV",
            "tokenA": moetAddress,
            "tokenB": morphoVaultAddress,
            "fee": 100 as UInt64,
            "tokenABalanceSlot": moetBalanceSlot,
            "tokenBBalanceSlot": fusdevBalanceSlot,
            "priceTokenBPerTokenA": fusdevDexPremium
        }
    ]
    
    for config in poolConfigs {
        let tokenA = config["tokenA"]! as! String
        let tokenB = config["tokenB"]! as! String
        let fee = config["fee"]! as! UInt64
        let tokenABalanceSlot = config["tokenABalanceSlot"]! as! UInt256
        let tokenBBalanceSlot = config["tokenBBalanceSlot"]! as! UInt256
        let priceRatio = config["priceTokenBPerTokenA"] != nil ? config["priceTokenBPerTokenA"]! as! UFix64 : 1.0
        
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: tokenA,
            tokenBAddress: tokenB,
            fee: fee,
            priceTokenBPerTokenA: priceRatio,
            tokenABalanceSlot: tokenABalanceSlot,
            tokenBBalanceSlot: tokenBBalanceSlot,
            signer: signer
        )
    }
    
    log("✓ All pools seeded")
}

// Set vault share price by multiplying current totalAssets by the given multiplier
// Manipulates both PYUSD0.balanceOf(vault) and vault._totalAssets to bypass maxRate capping
// Sets totalAssets to a large stable value (1e15) to prevent slippage
access(all) fun setVaultSharePrice(vaultAddress: String, priceMultiplier: UFix64, signer: Test.TestAccount) {
    // Use a large stable base value: 1e15 (1,000,000,000,000,000)
    // This prevents the vault from becoming too small/unstable during price changes
    let largeBaseAssets = UInt256.fromString("1000000000000000")!
    
    // Calculate target: largeBaseAssets * multiplier
    let multiplierBytes = priceMultiplier.toBigEndianBytes()
    var multiplierUInt64: UInt64 = 0
    for byte in multiplierBytes {
        multiplierUInt64 = (multiplierUInt64 << 8) + UInt64(byte)
    }
    let targetAssets = (largeBaseAssets * UInt256(multiplierUInt64)) / UInt256(100000000)
    
    let result = _executeTransaction(
        "transactions/set_erc4626_vault_price.cdc",
        [vaultAddress, pyusd0Address, UInt256(1), morphoVaultTotalAssetsSlot, priceMultiplier, targetAssets],
        signer
    )
    Test.expect(result, Test.beSucceeded())
}


// Set Uniswap V3 pool to a specific price via EVM.store
// Creates pool if it doesn't exist, then seeds with full-range liquidity
access(all) fun setPoolToPrice(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix64,
    tokenABalanceSlot: UInt256,
    tokenBBalanceSlot: UInt256,
    signer: Test.TestAccount
) {
    // Sort tokens (Uniswap V3 requires token0 < token1)
    let token0 = tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress
    let token1 = tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress
    let token0BalanceSlot = tokenAAddress < tokenBAddress ? tokenABalanceSlot : tokenBBalanceSlot
    let token1BalanceSlot = tokenAAddress < tokenBAddress ? tokenBBalanceSlot : tokenABalanceSlot
    
    let poolPrice = tokenAAddress < tokenBAddress ? priceTokenBPerTokenA : 1.0 / priceTokenBPerTokenA
    
    let targetSqrtPriceX96 = calculateSqrtPriceX96(price: poolPrice)
    let targetTick = calculateTick(price: poolPrice)
    
    let createResult = _executeTransaction(
        "transactions/create_uniswap_pool.cdc",
        [factoryAddress, token0, token1, fee, targetSqrtPriceX96],
        signer
    )
    
    let seedResult = _executeTransaction(
        "transactions/set_uniswap_v3_pool_price.cdc",
        [factoryAddress, token0, token1, fee, targetSqrtPriceX96, targetTick, token0BalanceSlot, token1BalanceSlot],
        signer
    )
    Test.expect(seedResult, Test.beSucceeded())
}


access(all) fun calculateSqrtPriceX96(price: UFix64): String {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places)
    // price is stored as integer * 10^8 internally
    let priceBytes = price.toBigEndianBytes()
    var priceUInt64: UInt64 = 0
    for byte in priceBytes {
        priceUInt64 = (priceUInt64 << 8) + UInt64(byte)
    }
    let priceScaled = UInt256(priceUInt64) // This is price * 10^8
    
    // We want: sqrt(price) * 2^96
    // = sqrt(priceScaled / 10^8) * 2^96
    // = sqrt(priceScaled) * 2^96 / sqrt(10^8)
    // = sqrt(priceScaled) * 2^96 / 10^4
    
    // Calculate sqrt(priceScaled) with scale factor 2^48 for precision
    // sqrt(priceScaled) * 2^48
    let sqrtPriceScaled = sqrt(n: priceScaled, scaleFactor: UInt256(1) << 48)
    
    // Now we have: sqrt(priceScaled) * 2^48
    // We want: sqrt(priceScaled) * 2^96 / 10^4
    // = (sqrt(priceScaled) * 2^48) * 2^48 / 10^4
    
    let sqrtPriceX96 = (sqrtPriceScaled * (UInt256(1) << 48)) / UInt256(10000)
    
    return sqrtPriceX96.toString()
}


// Calculate tick from price
// tick = ln(price) / ln(1.0001)
// ln(1.0001) ≈ 0.00009999500033... ≈ 99995000333 / 10^18
access(all) fun calculateTick(price: UFix64): Int256 {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places, stored as int * 10^8)
    let priceBytes = price.toBigEndianBytes()
    var priceUInt64: UInt64 = 0
    for byte in priceBytes {
        priceUInt64 = (priceUInt64 << 8) + UInt64(byte)
    }
    
    // priceUInt64 is price * 10^8
    // Scale to 10^18 for precision: price * 10^18 = priceUInt64 * 10^10
    let priceScaled = UInt256(priceUInt64) * UInt256(10000000000) // 10^10
    let scaleFactor = UInt256(1000000000000000000) // 10^18
    
    // Calculate ln(price) * 10^18
    let lnPrice = ln(x: priceScaled, scaleFactor: scaleFactor)
    
    // ln(1.0001) * 10^18 ≈ 99995000333083
    let ln1_0001 = Int256(99995000333083)
    
    // tick = ln(price) / ln(1.0001)
    // lnPrice is already scaled by 10^18
    // ln1_0001 is already scaled by 10^18  
    // So: tick = (lnPrice * 10^18) / (ln1_0001 * 10^18) = lnPrice / ln1_0001
    
    let tick = lnPrice / ln1_0001
    
    return tick
}


// Calculate square root using Newton's method for UInt256
// Returns sqrt(n) * scaleFactor to maintain precision
access(all) fun sqrt(n: UInt256, scaleFactor: UInt256): UInt256 {
    if n == UInt256(0) {
        return UInt256(0)
    }
    
    // Initial guess: n/2 (scaled)
    var x = (n * scaleFactor) / UInt256(2)
    var prevX = UInt256(0)
    
    // Newton's method: x_new = (x + n*scale^2/x) / 2
    // Iterate until convergence (max 50 iterations for safety)
    var iterations = 0
    while x != prevX && iterations < 50 {
        prevX = x
        // x_new = (x + (n * scaleFactor^2) / x) / 2
        let nScaled = n * scaleFactor * scaleFactor
        x = (x + nScaled / x) / UInt256(2)
        iterations = iterations + 1
    }
    
    return x
}


// Calculate natural logarithm using Taylor series
// ln(x) for x > 0, returns ln(x) * scaleFactor for precision
access(all) fun ln(x: UInt256, scaleFactor: UInt256): Int256 {
    if x == UInt256(0) {
        panic("ln(0) is undefined")
    }
    
    // For better convergence, reduce x to range [0.5, 1.5] using:
    // ln(x) = ln(2^n * y) = n*ln(2) + ln(y) where y is in [0.5, 1.5]
    
    var value = x
    var n = 0
    
    // Scale down if x > 1.5 * scaleFactor
    let threshold = (scaleFactor * UInt256(3)) / UInt256(2)
    while value > threshold {
        value = value / UInt256(2)
        n = n + 1
    }
    
    // Scale up if x < 0.5 * scaleFactor
    let lowerThreshold = scaleFactor / UInt256(2)
    while value < lowerThreshold {
        value = value * UInt256(2)
        n = n - 1
    }
    
    // Now value is in [0.5*scale, 1.5*scale], compute ln(value/scale)
    // Use Taylor series: ln(1+z) = z - z^2/2 + z^3/3 - z^4/4 + ...
    // where z = value/scale - 1
    
    let z = value > scaleFactor 
        ? Int256(value - scaleFactor)
        : -Int256(scaleFactor - value)
    
    // Calculate Taylor series terms until convergence
    var result = z // First term: z
    var term = z
    var i = 2
    var prevResult = Int256(0)
    
    // Calculate terms until convergence (term becomes negligible or result stops changing)
    // Max 50 iterations for safety
    while i <= 50 && result != prevResult {
        prevResult = result
        
        // term = term * z / scaleFactor
        term = (term * z) / Int256(scaleFactor)
        
        // Add or subtract term/i based on sign
        if i % 2 == 0 {
            result = result - term / Int256(i)
        } else {
            result = result + term / Int256(i)
        }
        i = i + 1
    }
    
    // Add n * ln(2) * scaleFactor
    // ln(2) ≈ 0.693147180559945309417232121458
    // ln(2) * 10^18 ≈ 693147180559945309
    let ln2Scaled = Int256(693147180559945309)
    let nScaled = Int256(n) * ln2Scaled
    
    // Scale to our scaleFactor (assuming scaleFactor is 10^18)
    result = result + nScaled
    
    return result
}

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            if balance.direction == FlowCreditMarket.BalanceDirection.Credit {
                return balance.balance
            }
        }
    }
    return 0.0
}


// Helper function to get MOET debt from position
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            if balance.direction == FlowCreditMarket.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}

