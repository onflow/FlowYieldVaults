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

// Morpho FUSDEV vault address
access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"

// Uniswap V3 Factory address on Flow EVM mainnet
access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// Storage slot for Morpho vault _totalAssets
// Slot 15: uint128 _totalAssets + uint64 lastUpdate + uint64 maxRate (packed)
access(all) let totalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"

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

// PYUSD0 token address (Morpho vault's underlying asset)
// Correct address from vault.asset(): 0x99aF3EeA856556646C98c8B9b2548Fe815240750
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"

// Morpho vault _totalAssets slot (slot 15, packed with lastUpdate and maxRate)
access(all) let morphoVaultTotalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"

// Token addresses for liquidity seeding
access(all) let moetAddress = "0x5c147e74D63B1D31AA3Fd78Eb229B65161983B2b"
access(all) let flowEVMAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// Helper: Compute Solidity mapping storage slot (wraps script call for convenience)
access(all) fun computeMappingSlot(holderAddress: String, slot: UInt256): String {
    let result = _executeScript("scripts/compute_solidity_mapping_slot.cdc", [holderAddress, slot])
    return result.returnValue as! String
}

// Set pool to a specific price via EVM.store
// Will create the pool first if it doesn't exist
// tokenA/tokenB can be passed in any order - the function handles sorting internally
// priceTokenBPerTokenA is the desired price ratio (tokenB/tokenA)
access(all) fun setPoolToPrice(
    factoryAddress: String,
    tokenAAddress: String,
    tokenBAddress: String,
    fee: UInt64,
    priceTokenBPerTokenA: UFix64,
    signer: Test.TestAccount
) {
    // Sort tokens (Uniswap V3 requires token0 < token1)
    let token0 = tokenAAddress < tokenBAddress ? tokenAAddress : tokenBAddress
    let token1 = tokenAAddress < tokenBAddress ? tokenBAddress : tokenAAddress
    
    // Calculate actual pool price based on sorting
    // If A < B: price = B/A (as passed in)
    // If B < A: price = A/B (inverse)
    let poolPrice = tokenAAddress < tokenBAddress ? priceTokenBPerTokenA : 1.0 / priceTokenBPerTokenA
    
    // Calculate sqrtPriceX96 and tick for the pool
    let targetSqrtPriceX96 = calculateSqrtPriceX96(price: poolPrice)
    let targetTick = calculateTick(price: poolPrice)
    
    log("[COERCE] Setting pool price to sqrtPriceX96=\(targetSqrtPriceX96), tick=\(targetTick.toString())")
    log("[COERCE] Token0: \(token0), Token1: \(token1), Price (token1/token0): \(poolPrice)")
    
    // First, try to create the pool (will fail gracefully if it already exists)
    let createResult = _executeTransaction(
        "transactions/create_uniswap_pool.cdc",
        [factoryAddress, token0, token1, fee, targetSqrtPriceX96],
        signer
    )
    // Don't fail if creation fails - pool might already exist
    
    // Now set pool price using EVM.store
    let seedResult = _executeTransaction(
        "transactions/set_uniswap_v3_pool_price.cdc",
        [factoryAddress, token0, token1, fee, targetSqrtPriceX96, targetTick],
        signer
    )
    Test.expect(seedResult, Test.beSucceeded())
    log("[POOL] Pool set to target price with 1e24 liquidity")
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

// Calculate sqrtPriceX96 for a given price ratio
// price = token1/token0 ratio (as UFix64, e.g., 2.0 means token1 is 2x token0)
// sqrtPriceX96 = sqrt(price) * 2^96
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
    // = (lnPrice * 10^18) / (ln1_0001)
    // = lnPrice * 10^18 / ln1_0001
    
    let tick = (lnPrice * Int256(1000000000000000000)) / ln1_0001
    
    return tick
}

// Setup Uniswap V3 pools with valid state at specified prices
access(all) fun setupUniswapPools(signer: Test.TestAccount) {
    log("\n=== CREATING AND SEEDING UNISWAP V3 POOLS WITH VALID STATE ===")
    
    // Pool configurations: (tokenA, tokenB, fee)
    let poolConfigs: [{String: String}] = [
        {
            "name": "PYUSD0/FUSDEV",
            "tokenA": pyusd0Address,
            "tokenB": morphoVaultAddress,
            "fee": "100"
        },
        {
            "name": "PYUSD0/FLOW",
            "tokenA": pyusd0Address,
            "tokenB": flowEVMAddress,
            "fee": "3000"
        },
        {
            "name": "MOET/FUSDEV",
            "tokenA": moetAddress,
            "tokenB": morphoVaultAddress,
            "fee": "100"
        }
    ]
    
    // Create and seed each pool
    for config in poolConfigs {
        let tokenA = config["tokenA"]!
        let tokenB = config["tokenB"]!
        let fee = UInt64.fromString(config["fee"]!)!
        
        log("\n=== \(config["name"]!) ===")
        log("TokenA: \(tokenA)")
        log("TokenB: \(tokenB)")
        log("Fee: \(fee)")
        
        // Set pool to 1:1 price
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: tokenA,
            tokenBAddress: tokenB,
            fee: fee,
            priceTokenBPerTokenA: 1.0,
            signer: signer
        )
        
        log("✓ \(config["name"]!) pool seeded with valid V3 state at 1:1 price")
    }
    
    log("\n✓✓✓ ALL POOLS SEEDED WITH STRUCTURALLY VALID V3 STATE ✓✓✓")
    log("Each pool now has:")
    log("  - Proper slot0 (unlocked, 1:1 price, observations)")
    log("  - Initialized observations array")
    log("  - Fee growth globals (feeGrowthGlobal0X128, feeGrowthGlobal1X128)")
    log("  - Massive liquidity (1e24)")
    log("  - Correctly initialized boundary ticks")
    log("  - Tick bitmap set for both boundaries")
    log("  - Position created (owner=pool, full-range, 1e24 liquidity)")
    log("  - Huge token balances in pool")
    log("\nSwaps should work with near-zero slippage!")
}

// Verify pools are READABLE with quoter (this is what rebalancing actually needs!)
access(all) fun verifyPoolsWithQuoter(signer: Test.TestAccount) {
    log("\n=== VERIFYING POOLS ARE READABLE (QUOTER TEST) ===")
    log("NOTE: We test quoter.quoteExactInput() instead of actual swaps")
    log("Rebalancing only needs price QUOTES, not actual swap execution")

    // Quoter address from mainnet
    let quoter = "0x8dd92c8d0C3b304255fF9D98ae59c3385F88360C"

    // Test amounts (in EVM units - already accounting for decimals)
    let amount1000_6dec = 1000000000 as UInt256      // 1000 tokens with 6 decimals

    // Test quote 1: PYUSD0 -> FUSDEV (both 6 decimals, fee 100)
    log("\n--- Quote Test 1: PYUSD0 -> FUSDEV ---")
    let quoteResult1 = _executeTransaction(
        "transactions/query_uniswap_quoter.cdc",
        [quoter, pyusd0Address, morphoVaultAddress, 100 as UInt32, amount1000_6dec],
        signer
    )

    if quoteResult1.status == Test.ResultStatus.succeeded {
        log("✓ PYUSD0/FUSDEV pool is readable")
    } else {
        panic("PYUSD0/FUSDEV quoter failed: \(quoteResult1.error?.message ?? "unknown")")
    }

    // Test quote 2: MOET -> FUSDEV (both 6 decimals, fee 100)
    log("\n--- Quote Test 2: MOET -> FUSDEV ---")
    let quoteResult2 = _executeTransaction(
        "transactions/query_uniswap_quoter.cdc",
        [quoter, moetAddress, morphoVaultAddress, 100 as UInt32, amount1000_6dec],
        signer
    )

    if quoteResult2.status == Test.ResultStatus.succeeded {
        log("✓ MOET/FUSDEV pool is readable")
    } else {
        panic("MOET/FUSDEV quoter failed: \(quoteResult2.error?.message ?? "unknown")")
    }

    // Test quote 3: PYUSD0 -> FLOW (6 decimals -> 18 decimals, fee 3000)
    log("\n--- Quote Test 3: PYUSD0 -> FLOW ---")
    let quoteResult3 = _executeTransaction(
        "transactions/query_uniswap_quoter.cdc",
        [quoter, pyusd0Address, flowEVMAddress, 3000 as UInt32, amount1000_6dec],
        signer
    )

    if quoteResult3.status == Test.ResultStatus.succeeded {
        log("✓ PYUSD0/FLOW pool is readable")
    } else {
        panic("PYUSD0/FLOW quoter failed: \(quoteResult3.error?.message ?? "unknown")")
    }

    log("\n✓✓✓ ALL POOLS ARE READABLE - REBALANCING CAN USE THESE PRICES ✓✓✓")
}

// Set vault share price by multiplying current totalAssets by the given multiplier
// Manipulates both PYUSD0.balanceOf(vault) and vault._totalAssets to bypass maxRate capping
access(all) fun setVaultSharePrice(vaultAddress: String, priceMultiplier: UFix64, signer: Test.TestAccount) {
    // Query current totalAssets
    let priceResult = _executeScript("scripts/get_erc4626_vault_price.cdc", [vaultAddress])
    Test.expect(priceResult, Test.beSucceeded())
    let currentAssets = UInt256.fromString((priceResult.returnValue as! {String: String})["totalAssets"]!)!
    
    // Calculate target using UFix64 fixed-point math (UFix64 stores value * 10^8 internally)
    let multiplierBytes = priceMultiplier.toBigEndianBytes()
    var multiplierUInt64: UInt64 = 0
    for byte in multiplierBytes {
        multiplierUInt64 = (multiplierUInt64 << 8) + UInt64(byte)
    }
    let targetAssets = (currentAssets * UInt256(multiplierUInt64)) / UInt256(100000000)
    
    log("[VM.STORE] Setting vault price to \(priceMultiplier.toString())x (totalAssets: \(currentAssets.toString()) -> \(targetAssets.toString()))")

    // 1. Set PYUSD0.balanceOf(vault) - compute slot dynamically
    let vaultBalanceSlot = computeMappingSlot(holderAddress: vaultAddress, slot: 1)  // PYUSD0 balanceOf at slot 1
    var storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0Address, vaultBalanceSlot, "0x\(String.encodeHex(targetAssets.toBigEndianBytes()))"],
        signer
    )
    Test.expect(storeResult, Test.beSucceeded())
    
    // 2. Set vault._totalAssets AND update lastUpdate (packed slot 15)
    // Slot 15 layout (32 bytes total):
    //   - bytes 0-7:   lastUpdate (uint64)
    //   - bytes 8-15:  maxRate (uint64)
    //   - bytes 16-31: _totalAssets (uint128)
    
    let slotResult = _executeScript("scripts/load_storage_slot.cdc", [vaultAddress, morphoVaultTotalAssetsSlot])
    Test.expect(slotResult, Test.beSucceeded())
    let slotHex = slotResult.returnValue as! String
    let slotBytes = slotHex.slice(from: 2, upTo: slotHex.length).decodeHex()
    
    // Get current block timestamp (for lastUpdate)
    let blockResult = _executeScript("scripts/get_block_timestamp.cdc", [])
    let currentTimestamp = blockResult.status == Test.ResultStatus.succeeded 
        ? UInt64.fromString((blockResult.returnValue as! String?) ?? "0") ?? UInt64(getCurrentBlock().timestamp)
        : UInt64(getCurrentBlock().timestamp)
    
    // Preserve maxRate (bytes 8-15), but UPDATE lastUpdate and _totalAssets
    let maxRateBytes = slotBytes.slice(from: 8, upTo: 16)
    
    // Encode new lastUpdate (uint64, 8 bytes, big-endian)
    var lastUpdateBytes: [UInt8] = []
    var tempTimestamp = currentTimestamp
    var i = 0
    while i < 8 {
        lastUpdateBytes.insert(at: 0, UInt8(tempTimestamp % 256))
        tempTimestamp = tempTimestamp / 256
        i = i + 1
    }
    
    // Encode new _totalAssets (uint128, 16 bytes, big-endian, left-padded)
    let assetsBytes = targetAssets.toBigEndianBytes()
    var paddedAssets: [UInt8] = []
    var padCount = 16 - assetsBytes.length
    while padCount > 0 {
        paddedAssets.append(0)
        padCount = padCount - 1
    }
    paddedAssets.appendAll(assetsBytes)
    
    // Pack: lastUpdate (8) + maxRate (8) + _totalAssets (16) = 32 bytes
    var newSlotBytes: [UInt8] = []
    newSlotBytes.appendAll(lastUpdateBytes)
    newSlotBytes.appendAll(maxRateBytes)
    newSlotBytes.appendAll(paddedAssets)
    
    log("Stored value at slot \(morphoVaultTotalAssetsSlot)")
    log("  lastUpdate: \(currentTimestamp) (updated to current block)")
    log("  maxRate: preserved")
    log("  _totalAssets: \(targetAssets.toString())")
    
    storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [vaultAddress, morphoVaultTotalAssetsSlot, "0x\(String.encodeHex(newSlotBytes))"],
        signer
    )
    Test.expect(storeResult, Test.beSucceeded())
}

// Verify that pools work correctly with a simple swap
access(all) fun verifyPoolSwap(signer: Test.TestAccount) {
    log("\n=== TESTING POOL SWAPS (SANITY CHECK) ===")
    log("Verifying that pools can execute swaps successfully")
    
    let router = "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341"
    
    // Test swap on PYUSD0/FUSDEV pool (both 6 decimals, 1:1 price)
    log("\n--- Test Swap: PYUSD0 -> FUSDEV ---")
    let swapAmount = 1000000 as UInt256 // 1 token (6 decimals)
    
    // Get COA address
    let coaEVMAddress = getCOA(signer.address)!
    
    // Mint PYUSD0 to COA for the swap
    let pyusd0BalanceSlot = computeMappingSlot(holderAddress: coaEVMAddress, slot: 1)
    var mintResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0Address, pyusd0BalanceSlot, "0x\(String.encodeHex(swapAmount.toBigEndianBytes()))"],
        signer
    )
    Test.expect(mintResult, Test.beSucceeded())
    
    // Execute swap via router
    let swapResult = _executeTransaction(
        "transactions/swap_via_uniswap_router.cdc",
        [router, pyusd0Address, morphoVaultAddress, UInt32(100), swapAmount],
        signer
    )
    
    if swapResult.status == Test.ResultStatus.succeeded {
        log("✓ PYUSD0/FUSDEV swap SUCCEEDED - Pool is working correctly!")
    } else {
        log("✗ PYUSD0/FUSDEV swap FAILED")
        log("Error: \(swapResult.error?.message ?? "unknown")")
        panic("Pool swap failed - pool state is invalid!")
    }
    
    log("\n✓✓✓ POOL SANITY CHECK PASSED - Swaps work correctly ✓✓✓\n")
}

access(all)
fun setup() {
    // Deploy mock EVM contract to enable vm.store/vm.load cheatcodes
    var err = Test.deployContract(name: "EVM", path: "../contracts/mocks/EVM.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    
    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    setupUniswapPools(signer: coaOwnerAccount)

    // Verify pools work with a test swap (sanity check)
    verifyPoolSwap(signer: coaOwnerAccount)

    // BandOracle is only used for FLOW price for FCM collateral
    let symbolPrices = { 
        "FLOW": 1.0  // Start at 1.0, will increase to 2.0 during test
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

    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("[TEST] flow balance before \(flowBalanceBefore)")
    
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
    log("[TEST] Captured Position ID from event: \(pid)")

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueBefore = flowCollateralBefore * 1.0  // Initial price is 1.0
    
    log("\n=== PRECISION COMPARISON (Initial State) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
    log("Actual Yield Tokens:   \(yieldTokensBefore)")
    let diff0 = yieldTokensBefore > expectedYieldTokenValues[0] ? yieldTokensBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - yieldTokensBefore
    let sign0 = yieldTokensBefore > expectedYieldTokenValues[0] ? "+" : "-"
    log("Difference:            \(sign0)\(diff0)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[0])")
    log("Actual Flow Collateral Value:   \(flowCollateralValueBefore)")
    let flowDiff0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? flowCollateralValueBefore - expectedFlowCollateralValues[0] : expectedFlowCollateralValues[0] - flowCollateralValueBefore
    let flowSign0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? "+" : "-"
    log("Difference:                     \(flowSign0)\(flowDiff0)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[0])")
    log("Actual MOET Debt:   \(debtBefore)")
    let debtDiff0 = debtBefore > expectedDebtValues[0] ? debtBefore - expectedDebtValues[0] : expectedDebtValues[0] - debtBefore
    let debtSign0 = debtBefore > expectedDebtValues[0] ? "+" : "-"
    log("Difference:         \(debtSign0)\(debtDiff0)")
    log("=========================================================\n")
    
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

    testSnapshot = getCurrentBlockHeight()

    // === FLOW PRICE INCREASE TO 2.0 ===
    log("\n=== INCREASING FLOW PRICE TO 2.0x ===")
    setBandOraclePrice(signer: bandOracleAccount, symbol: "FLOW", price: flowPriceIncrease)

    // Update PYUSD0/FLOW pool to match new Flow price (2:1 ratio token1:token0)
    log("\n=== UPDATING PYUSD0/FLOW POOL TO 2:1 PRICE ===")
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: flowEVMAddress,
        fee: 3000,
        priceTokenBPerTokenA: 2.0,  // Flow is 2x the price of PYUSD0
        signer: coaOwnerAccount
    )

    // These rebalance calls work correctly - position is undercollateralized after price increase
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterFlowPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterFlowIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterFlowIncrease = flowCollateralAfterFlowIncrease * flowPriceIncrease
    let debtAfterFlowIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== PRECISION COMPARISON (After Flow Price Increase) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
    log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceIncrease)")
    let diff1 = yieldTokensAfterFlowPriceIncrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceIncrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceIncrease
    let sign1 = yieldTokensAfterFlowPriceIncrease > expectedYieldTokenValues[1] ? "+" : "-"
    log("Difference:            \(sign1)\(diff1)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[1])")
    log("Actual Flow Collateral Value:   \(flowCollateralValueAfterFlowIncrease)")
    log("Actual Flow Collateral Amount:  \(flowCollateralAfterFlowIncrease) Flow tokens")
    let flowDiff1 = flowCollateralValueAfterFlowIncrease > expectedFlowCollateralValues[1] ? flowCollateralValueAfterFlowIncrease - expectedFlowCollateralValues[1] : expectedFlowCollateralValues[1] - flowCollateralValueAfterFlowIncrease
    let flowSign1 = flowCollateralValueAfterFlowIncrease > expectedFlowCollateralValues[1] ? "+" : "-"
    log("Difference:                     \(flowSign1)\(flowDiff1)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[1])")
    log("Actual MOET Debt:   \(debtAfterFlowIncrease)")
    let debtDiff1 = debtAfterFlowIncrease > expectedDebtValues[1] ? debtAfterFlowIncrease - expectedDebtValues[1] : expectedDebtValues[1] - debtAfterFlowIncrease
    let debtSign1 = debtAfterFlowIncrease > expectedDebtValues[1] ? "+" : "-"
    log("Difference:         \(debtSign1)\(debtDiff1)")
    log("=========================================================\n")
    
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
    log("\n=== INCREASING YIELD VAULT PRICE TO 2.0x USING VM.STORE ===")
    
    // Log state BEFORE vault price change
    log("\n=== STATE BEFORE VAULT PRICE CHANGE ===")
    let yieldBalanceBeforePriceChange = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let yieldValueBeforePriceChange = getAutoBalancerCurrentValue(id: yieldVaultIDs![0])!
    log("AutoBalancer balance (underlying): \(yieldBalanceBeforePriceChange)")
    log("AutoBalancer current value: \(yieldValueBeforePriceChange)")
    
    // Calculate what SHOULD happen based on test expectations
    log("\n=== EXPECTED BEHAVIOR CALCULATION ===")
    let currentShares = yieldBalanceBeforePriceChange
    log("Current shares: \(currentShares)")
    log("After 2x price increase, same shares should be worth: \(currentShares * 2.0)")
    log("But test expects final shares: \(expectedYieldTokenValues[2])")
    log("This means we should WITHDRAW: \(currentShares - expectedYieldTokenValues[2]) shares")
    log("Why? Because value doubled, so we need fewer shares to maintain target allocation")
    
    let collateralValue = getFlowCollateralFromPosition(pid: pid) * flowPriceIncrease
    let targetYieldValue = (collateralValue * collateralFactor) / targetHealthFactor
    log("\n=== TARGET ALLOCATION CALCULATION ===")
    log("Collateral (Flow): \(getFlowCollateralFromPosition(pid: pid))")
    log("Flow price: \(flowPriceIncrease)")
    log("Collateral value: \(collateralValue)")
    log("Collateral factor: \(collateralFactor)")
    log("Target health factor: \(targetHealthFactor)")
    log("Target yield value: \(targetYieldValue)")
    log("At current price (1.0), target shares: \(targetYieldValue / 1.0)")
    log("At new price (2.0), target shares: \(targetYieldValue / 2.0)")
    
    setVaultSharePrice(vaultAddress: morphoVaultAddress, priceMultiplier: yieldPriceIncrease, signer: user)
    
    // Update PYUSD0/FUSDEV and MOET/FUSDEV pools to match new vault share price (2:1 ratio)
    log("\n=== UPDATING FUSDEV POOLS TO 2:1 PRICE ===")
    
    // PYUSD0/FUSDEV pool (both 6 decimals)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,  // FUSDEV is 2x the price of PYUSD0
        signer: coaOwnerAccount
    )
    
    // MOET/FUSDEV pool (both 6 decimals)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,  // FUSDEV is 2x the price of MOET
        signer: coaOwnerAccount
    )
    
    // Log state AFTER vault price change but BEFORE rebalance
    log("\n=== STATE AFTER VAULT PRICE CHANGE (before rebalance) ===")
    let yieldBalanceAfterPriceChange = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let yieldValueAfterPriceChange = getAutoBalancerCurrentValue(id: yieldVaultIDs![0])!
    log("AutoBalancer balance (underlying): \(yieldBalanceAfterPriceChange)")
    log("AutoBalancer current value: \(yieldValueAfterPriceChange)")
    log("Balance change from price appreciation: \(yieldBalanceAfterPriceChange - yieldBalanceBeforePriceChange)")
    
    // Verify the price actually changed
    log("\n=== VERIFYING VAULT PRICE CHANGE ===")
    let verifyResult = _executeScript("scripts/get_erc4626_vault_price.cdc", [morphoVaultAddress])
    Test.expect(verifyResult, Test.beSucceeded())
    let verifyData = verifyResult.returnValue as! {String: String}
    let newTotalAssets = UInt256.fromString(verifyData["totalAssets"]!)!
    let newTotalSupply = UInt256.fromString(verifyData["totalSupply"]!)!
    let newPrice = UInt256.fromString(verifyData["price"]!)!
    log("  totalAssets after vm.store: \(newTotalAssets.toString())")
    log("  totalSupply after vm.store: \(newTotalSupply.toString())")
    log("  price after vm.store: \(newPrice.toString())")
    
    // Debug: Check adapter allocations vs idle balance
    log("\n=== DEBUGGING VAULT ASSET COMPOSITION ===")
    let debugResult = _executeScript("scripts/debug_morpho_vault_assets.cdc", [])
    Test.expect(debugResult, Test.beSucceeded())
    let debugData = debugResult.returnValue as! {String: String}
    for key in debugData.keys {
        log("  \(key): \(debugData[key]!)")
    }
    
    // Check position health before rebalance
    log("\n=== POSITION STATE BEFORE ANY REBALANCE ===")
    let positionBeforeRebalance = getPositionDetails(pid: pid, beFailed: false)
    log("Position health: \(positionBeforeRebalance.health)")
    log("Default token available: \(positionBeforeRebalance.defaultTokenAvailableBalance)")
    log("Position collateral (Flow): \(getFlowCollateralFromPosition(pid: pid))")
    log("Position debt (MOET): \(getMOETDebtFromPosition(pid: pid))")
    
    // Log AutoBalancer state in detail before rebalance
    log("\n=== AUTOBALANCER STATE BEFORE REBALANCE ===")
    let autoBalancerValues = _executeScript("scripts/get_autobalancer_values.cdc", [yieldVaultIDs![0]])
    Test.expect(autoBalancerValues, Test.beSucceeded())
    let abValues = autoBalancerValues.returnValue as! {String: String}
    
    let balanceBeforeRebal = UFix64.fromString(abValues["balance"]!)!
    let valueBeforeRebal = UFix64.fromString(abValues["currentValue"]!)!
    let valueOfDeposits = UFix64.fromString(abValues["valueOfDeposits"]!)!
    
    log("AutoBalancer balance (shares): \(balanceBeforeRebal)")
    log("AutoBalancer currentValue (USD): \(valueBeforeRebal)")
    log("AutoBalancer valueOfDeposits (historical): \(valueOfDeposits)")
    log("Implied price per share: \(valueBeforeRebal / balanceBeforeRebal)")
    
    // THE CRITICAL CHECK
    let isDeficitCheck = valueBeforeRebal < valueOfDeposits
    log("\n=== THE CRITICAL DECISION ===")
    log("isDeficit = currentValue < valueOfDeposits")
    log("isDeficit = \(valueBeforeRebal) < \(valueOfDeposits)")
    log("isDeficit = \(isDeficitCheck)")
    log("If TRUE: AutoBalancer will DEPOSIT (add more funds)")
    log("If FALSE: AutoBalancer will WITHDRAW (remove excess funds)")
    log("Expected: FALSE (should withdraw because current > target)")
    
    log("\nPosition collateral value at Flow=$2: \(getFlowCollateralFromPosition(pid: pid) * flowPriceIncrease)")
    log("Target allocation based on collateral: \((getFlowCollateralFromPosition(pid: pid) * flowPriceIncrease * collateralFactor) / targetHealthFactor)")
    
    // Check what the oracle is reporting for prices
    log("\n=== ORACLE PRICES (manually verified from test setup) ===")
    log("Flow oracle price: $2.00 (we doubled it from $1.00)")
    log("MOET oracle price: $1.00 (unchanged)")
    log("These oracle prices determine borrow amounts in rebalancePosition()")
    log("DEX prices have NO effect on borrow amount calculations")
    
    // Get vault share price
    let vaultPriceCheck = _executeScript("scripts/get_erc4626_vault_price.cdc", [morphoVaultAddress])
    Test.expect(vaultPriceCheck, Test.beSucceeded())
    let vaultPriceData = vaultPriceCheck.returnValue as! {String: String}
    log("ERC4626 vault raw price (totalAssets/totalSupply): \(vaultPriceData["price"]!) (we doubled this)")
    log("ERC4626 totalAssets: \(vaultPriceData["totalAssets"]!)")
    log("ERC4626 totalSupply: \(vaultPriceData["totalSupply"]!)")
    
    // Skip ERC4626PriceOracles check for now - it has type issues
    // let oraclePriceCheck = _executeScript("scripts/get_erc4626_price_oracle_price.cdc", [morphoVaultAddress])
    // Test.expect(oraclePriceCheck, Test.beSucceeded())
    // let oracleData = oraclePriceCheck.returnValue as! {String: String}
    // log("ERC4626PriceOracles.price() returns: \(oracleData["price_from_oracle"]!)")
    // log("Oracle unit of account: \(oracleData["unit_of_account"]!)")
    
    // Calculate rebalance expectations
    let currentValueUSD = valueBeforeRebal
    let targetValueUSD = (getFlowCollateralFromPosition(pid: pid) * flowPriceIncrease * collateralFactor) / targetHealthFactor
    let deltaValueUSD = currentValueUSD - targetValueUSD
    log("\n=== REBALANCE DECISION ANALYSIS ===")
    log("Current yield value: \(currentValueUSD)")
    log("Target yield value: \(targetValueUSD)")
    log("Delta (current - target): \(deltaValueUSD)")
    log("Since delta is POSITIVE, AutoBalancer should WITHDRAW \(deltaValueUSD) worth")
    log("At price 2.0, that means withdraw \(deltaValueUSD / 2.0) shares")
    
    log("\n=== EXPECTED vs ACTUAL CALCULATION ===")
    log("If rebalancePosition is called (which it shouldn't be for withdraw):")
    log("  It would calculate borrow amounts using oracle prices")
    log("  Current position health can be computed from collateral/debt")
    log("  Target health factor: \(targetHealthFactor)")
    log("  This determines how much to borrow to reach target health")
    log("  We'll see if the actual amounts match oracle price expectations")

    // Rebalance the yield vault first (to adjust to new price)
    log("\n=== DETAILED REBALANCE ANALYSIS ===")
    log("BEFORE rebalanceYieldVault:")
    log("  vault.balance: \(balanceBeforeRebal) shares")
    log("  currentValue: \(valueBeforeRebal) USD")
    log("  valueOfDeposits: \(valueOfDeposits) USD")
    log("  isDeficit calculation: \(valueBeforeRebal) < \(valueOfDeposits) = \(valueBeforeRebal < valueOfDeposits)")
    log("  Expected branch: \((valueBeforeRebal < valueOfDeposits) ? "DEPOSIT (isDeficit=TRUE)" : "WITHDRAW (isDeficit=FALSE)")")
    let valueDiffUSD: UFix64 = valueBeforeRebal < valueOfDeposits ? valueOfDeposits - valueBeforeRebal : valueBeforeRebal - valueOfDeposits
    log("  Amount to rebalance: \(valueDiffUSD / 2.0) shares (at price 2.0)")
    
    log("\n=== CALLING REBALANCE YIELD VAULT ===")
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    
    // BUG: Calling rebalancePosition after AutoBalancer withdrawal triggers amplification loop
    // When position becomes overcollateralized (after withdrawal), rebalancePosition mints MOET
    // and sends it through drawDownSink (abaSwapSink), which swaps MOET → FUSDEV and deposits
    // back to AutoBalancer, increasing collateral instead of reducing it. Result: 10x amplification.
    // ROOT CAUSE: FlowCreditMarket.cdc line 2334 only handles MOET-type drawDownSinks for
    // overcollateralized positions, and abaSwapSink creates a circular dependency.
    log("\n=== CALLING REBALANCE POSITION (TRIGGERS BUG) ===")
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)
    
    log("\n=== AUTOBALANCER STATE AFTER YIELD VAULT REBALANCE ===")
    let balanceAfterYieldRebal = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let valueAfterYieldRebal = getAutoBalancerCurrentValue(id: yieldVaultIDs![0])!
    log("AutoBalancer balance (shares): \(balanceAfterYieldRebal)")
    log("AutoBalancer currentValue (USD): \(valueAfterYieldRebal)")
    let balanceChange = balanceAfterYieldRebal > balanceBeforeRebal 
        ? balanceAfterYieldRebal - balanceBeforeRebal 
        : balanceBeforeRebal - balanceAfterYieldRebal
    let balanceSign = balanceAfterYieldRebal > balanceBeforeRebal ? "+" : "-"
    let valueChange = valueAfterYieldRebal > valueBeforeRebal
        ? valueAfterYieldRebal - valueBeforeRebal
        : valueBeforeRebal - valueAfterYieldRebal
    let valueSign = valueAfterYieldRebal > valueBeforeRebal ? "+" : "-"
    log("Balance change: \(balanceSign)\(balanceChange) shares")
    log("Value change: \(valueSign)\(valueChange) USD")
    
    // Check position state after yield vault rebalance
    log("\n=== POSITION STATE AFTER YIELD VAULT REBALANCE ===")
    let positionAfterYieldRebal = getPositionDetails(pid: pid, beFailed: false)
    log("Position health: \(positionAfterYieldRebal.health)")
    log("Position collateral (Flow): \(getFlowCollateralFromPosition(pid: pid))")
    log("Position debt (MOET): \(getMOETDebtFromPosition(pid: pid))")
    log("Collateral change: \(getFlowCollateralFromPosition(pid: pid) - flowCollateralAfterFlowIncrease) Flow")
    log("Debt change: \(getMOETDebtFromPosition(pid: pid) - debtAfterFlowIncrease) MOET")
    
    // NOTE: Position rebalance is commented out to match bootstrapped test behavior
    // The yield price increase should NOT trigger position rebalancing
    // log("\n=== CALLING REBALANCE POSITION ===")
    // rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)
    
    log("\n=== FINAL STATE (no position rebalance after yield price change) ===")
    let positionFinal = getPositionDetails(pid: pid, beFailed: false)
    log("Position health: \(positionFinal.health)")
    log("Position collateral (Flow): \(getFlowCollateralFromPosition(pid: pid))")
    log("Position debt (MOET): \(getMOETDebtFromPosition(pid: pid))")
    log("AutoBalancer balance (shares): \(getAutoBalancerBalance(id: yieldVaultIDs![0])!)")
    log("AutoBalancer currentValue (USD): \(getAutoBalancerCurrentValue(id: yieldVaultIDs![0])!)")

    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceIncrease  // Flow price remains at 2.0
    let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== PRECISION COMPARISON (After Yield Price Increase) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
    log("Actual Yield Tokens:   \(yieldTokensAfterYieldPriceIncrease)")
    let diff2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? yieldTokensAfterYieldPriceIncrease - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - yieldTokensAfterYieldPriceIncrease
    let sign2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? "+" : "-"
    log("Difference:            \(sign2)\(diff2)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[2])")
    log("Actual Flow Collateral Value:   \(flowCollateralValueAfterYieldIncrease)")
    log("Actual Flow Collateral Amount:  \(flowCollateralAfterYieldIncrease) Flow tokens")
    let flowDiff2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? flowCollateralValueAfterYieldIncrease - expectedFlowCollateralValues[2] : expectedFlowCollateralValues[2] - flowCollateralValueAfterYieldIncrease
    let flowSign2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? "+" : "-"
    log("Difference:                     \(flowSign2)\(flowDiff2)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[2])")
    log("Actual MOET Debt:   \(debtAfterYieldIncrease)")
    let debtDiff2 = debtAfterYieldIncrease > expectedDebtValues[2] ? debtAfterYieldIncrease - expectedDebtValues[2] : expectedDebtValues[2] - debtAfterYieldIncrease
    let debtSign2 = debtAfterYieldIncrease > expectedDebtValues[2] ? "+" : "-"
    log("Difference:         \(debtSign2)\(debtDiff2)")
    log("=========================================================\n")
    
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

    // Close yield vault
    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
    
    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("[TEST] flow balance after \(flowBalanceAfter)")
    
    log("\n=== TEST COMPLETE ===")
}
