// Scenario 3D: Flow price decreases 0.5x, Yield vault price increases 1.5x
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

// MOET - Flow ALP USD
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

    // BandOracle is only used for FLOW price for FCM collateral
    let symbolPrices = { 
        "FLOW": 1.0  // Start at 1.0, will decrease to 0.5 during test
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
fun test_ForkedRebalanceYieldVaultScenario3D() {
    let fundingAmount = 1000.0
    let flowPriceDecrease = 0.5     // Flow price drops to 0.5x
    let yieldPriceIncrease = 1.5    // Yield vault price increases to 1.5x

    let expectedYieldTokenValues = [615.38461539, 307.69230769, 268.24457594]
    let expectedFlowCollateralValues = [1000.0, 500.0, 653.84615385]
    let expectedDebtValues = [615.38461539, 307.69230769, 402.36686391]

    let user = Test.createAccount()
    
    mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    log("\n=== Creating Yield Vault ===")
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

    log("\n=== Initial State ===")
    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensBefore) (expected: \(expectedYieldTokenValues[0]))")
    log("Flow Collateral: \(flowCollateralBefore) FLOW")
    log("MOET Debt: \(debtBefore)")
    
    Test.assert(
        equalAmounts(a: yieldTokensBefore, b: expectedYieldTokenValues[0], tolerance: expectedYieldTokenValues[0] * forkedPercentTolerance),
        message: "Expected yield tokens to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
    )

    log("\n=== FLOW PRICE → \(flowPriceDecrease)x ===")
    // Set FLOW price to 0.5 via Band Oracle (for FCM collateral calculation)
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: { "FLOW": flowPriceDecrease })
    
    // Set FLOW/MOET pool to reflect 0.5x price (FLOW is worth half as much)
    // At 0.5x: 1 FLOW = 0.5 MOET, so priceTokenBPerTokenA = 0.5
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: moetAddress,
        fee: 3000,
        priceTokenBPerTokenA: flowPriceDecrease,
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: moetBalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    log("\n=== After Flow Price Decrease ===")
    let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterFlowDecrease = getFlowCollateralFromPosition(pid: pid)
    let debtAfterFlowDecrease = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensAfterFlowPriceDecrease) (expected: \(expectedYieldTokenValues[1]))")
    log("Flow Collateral: \(flowCollateralAfterFlowDecrease) FLOW (value: $\(flowCollateralAfterFlowDecrease * flowPriceDecrease))")
    log("MOET Debt: \(debtAfterFlowDecrease)")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterFlowPriceDecrease, b: expectedYieldTokenValues[1], tolerance: expectedYieldTokenValues[1] * forkedPercentTolerance),
        message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
    )

    log("\n=== YIELD VAULT PRICE → \(yieldPriceIncrease)x ===")
    // Set vault share price to 1.5x by manipulating totalAssets
    setVaultSharePrice(vaultAddress: morphoVaultAddress, priceMultiplier: yieldPriceIncrease, signer: coaOwnerAccount)
    
    // Set FUSDEV/FLOW pool to reflect 1.5x price increase
    // At baseline: 1 FUSDEV = 1 FLOW (when both at $1)
    // At 1.5x FUSDEV price and 0.5x FLOW price: 1 FUSDEV = 3 FLOW
    // So priceTokenBPerTokenA (FLOW per FUSDEV) = 3.0
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 3.0,  // 1.5 / 0.5 = 3
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )
    
    // Set PYUSD0/FLOW pool (FUSDEV's underlying asset)
    // PYUSD0 is $1 stablecoin, FLOW is $0.5, so 1 PYUSD0 = 2 FLOW
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 500,
        priceTokenBPerTokenA: 2.0,  // 1.0 / 0.5 = 2
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

    log("\n=== After Yield Vault Price Increase ===")
    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
    let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensAfterYieldPriceIncrease) (expected: \(expectedYieldTokenValues[2]))")
    log("Flow Collateral: \(flowCollateralAfterYieldIncrease) FLOW (value: $\(flowCollateralAfterYieldIncrease * flowPriceDecrease))")
    log("MOET Debt: \(debtAfterYieldIncrease)")
    
    // Check if rebalancing behaved correctly
    if yieldTokensAfterYieldPriceIncrease < expectedYieldTokenValues[1] {
        log("BUG: Should have DEPOSITED to \(expectedYieldTokenValues[2]), but WITHDREW instead!")
    } else if yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[1] {
        log("BUG: Should have WITHDRAWN to \(expectedYieldTokenValues[2]), but DEPOSITED instead!")
    }
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterYieldPriceIncrease, b: expectedYieldTokenValues[2], tolerance: expectedYieldTokenValues[2] * forkedPercentTolerance),
        message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralAfterYieldIncrease * flowPriceDecrease, b: expectedFlowCollateralValues[2], tolerance: expectedFlowCollateralValues[2] * forkedPercentTolerance),
        message: "Expected flow collateral value after yield price increase to be \(expectedFlowCollateralValues[2]) but got \(flowCollateralAfterYieldIncrease * flowPriceDecrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterYieldIncrease, b: expectedDebtValues[2], tolerance: expectedDebtValues[2] * forkedPercentTolerance),
        message: "Expected MOET debt after yield price increase to be \(expectedDebtValues[2]) but got \(debtAfterYieldIncrease)"
    )

    log("\n=== TEST COMPLETE ===")
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
    Test.expect(createResult, Test.beSucceeded())
    
    let seedResult = _executeTransaction(
        "transactions/set_uniswap_v3_pool_price.cdc",
        [factoryAddress, token0, token1, fee, targetSqrtPriceX96, targetTick, token0BalanceSlot, token1BalanceSlot],
        signer
    )
    Test.expect(seedResult, Test.beSucceeded())
}

// Calculate sqrt(price) * 2^96 for Uniswap V3
access(all) fun calculateSqrtPriceX96(price: UFix64): String {
    // Convert UFix64 to UInt256 (UFix64 has 8 decimal places, stored as int * 10^8)
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

access(all) fun setupUniswapPools(signer: Test.TestAccount) {
    log("\n=== Setting up Uniswap V3 pools ===")
    
    // MOET/FLOW pool at 1:1 (both $1)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: signer
    )
    
    // FUSDEV/FLOW pool at 1:1 (both $1)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: signer
    )
    
    // PYUSD0/FLOW pool at 1:1 (both $1)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 500,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: signer
    )
    
    log("✓ All pools seeded")
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
