// this height guarantees enough liquidity for the test
#test_fork(network: "mainnet", height: 140164761)

import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "FlowYieldVaultsStrategiesV1_1"
import "FlowCreditMarket"
import "FlowYieldVaults"
import "ERC4626PriceOracles"

// check (and update) flow.json for correct addresses
// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let yieldTokenAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV1_1.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

// Morpho FUSDEV vault address
access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"

// Storage slot for Morpho vault _totalAssets
// Slot 15: uint128 _totalAssets + uint64 lastUpdate + uint64 maxRate (packed)
access(all) let totalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"

// PYUSD address (underlying asset of FUSDEV)
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"

// PYUSD0 balanceOf mapping is at slot 1 (standard ERC20 layout)
// Storage slot for balanceOf[morphoVault] = keccak256(vault_address_padded || slot_1)
// Calculated using: cast keccak 0x000000000000000000000000d069d989e2f44b70c65347d1853c0c67e10a9f8d0000000000000000000000000000000000000000000000000000000000000001
access(all) let pyusd0BalanceSlotForVault = "0x00056c3aa1845366a3744ff6c51cff309159d9be9eacec9ff06ec523ae9db7f0"

// Morpho vault _totalAssets slot (slot 15, packed with lastUpdate and maxRate)
access(all) let morphoVaultTotalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"

// Token addresses for liquidity seeding
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"
access(all) let flowEVMAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// Storage slots for balanceOf[COA] where COA = 0xe467b9dd11fa00df
// Calculated via: cast index address 0x000000000000000000000000e467b9dd11fa00df <slot>
access(all) let moetBalanceSlotForCOA = "0x00163bda938054c6ef029aa834a66783a57ce7bedb1a8c2815e8bdf7ab9ddb39"  // MOET slot 0
access(all) let pyusd0BalanceSlotForCOA = "0xb2beb48b003c8e5b001f84bc854c4027531bf1261e8e308e47f3edf075df5ab5"  // PYUSD0 slot 1
access(all) let flowBalanceSlotForCOA = "0xc17ff7261d01d5856dbab5ec0876860faa2c19391118938e463d89cdcee92ff1"  // WFLOW slot 3 (WETH9: name=0, symbol=1, decimals=2, balanceOf=3)

access(all) var snapshot: UInt64 = 0
access(all) var baselineTotalAssets: UInt256 = 0

// Uniswap V3 pool addresses (token0 < token1 by address in all cases)
access(all) let pyusd0FusdevPoolAddr = "0x9196e243b7562b0866309013f2f9eb63f83a690f"  // PYUSD0/FUSDEV fee 100
access(all) let pyusd0FlowPoolAddr = "0x0fdba612fea7a7ad0256687eebf056d81ca63f63"    // PYUSD0/FLOW fee 3000
access(all) let moetFusdevPoolAddr = "0xeAace6532D52032E748a15F9FC1eaaB784dF240c"    // MOET/FUSDEV fee 100

// UniV3 pool slot 0 = EVM storage slot 0x00 (contains sqrtPriceX96, tick, observation metadata, unlocked)
access(all) let uniV3Slot0StorageSlot = "0x0000000000000000000000000000000000000000000000000000000000000000"

// Precomputed UniV3 slot0 values for pools with 6-vs-18 decimal tokens at 1:1 VALUE pricing
// (sqrtPriceX96 = 10^6 * 2^96, tick = 276324, observationCardinality=1, unlocked=true)
// Used for PYUSD/WFLOW pool (constant: 1 PYUSD = 1 FLOW)
access(all) let slot0_1to1_value_6vs18 = "0x00010000010001000004376400000000000f4240000000000000000000000000"

// Precomputed slot0 values for PYUSD/FUSDEV pool (6-vs-18 decimal tokens) at each yield price P
// When 1 FUSDEV share = P PYUSD: price_raw = 10^12/P (decimal adjustment: 18 - 6 = 12)
// sqrtPriceX96 = sqrt(10^12/P) * 2^96, tick = floor(ln(10^12/P) / ln(1.0001))
// Layout: [padding:1][unlocked:1][feeProtocol:1][obsCardNext:2][obsCard:2][obsIdx:2][tick:3][sqrtPriceX96:20] = 32 bytes
access(all) let pyusdFusdevPoolSlot0: {String: String} = {
    "1.00000000": "0x00010000010001000004376400000000000f4240000000000000000000000000",
    "1.10000000": "0x0001000001000100000433aa00000000000e8c7696d8cc940000000000000000",
    "1.20000000": "0x00010000010001000004304400000000000dede6edde6e528000000000000000",
    "1.30000000": "0x000100000100010000042d2400000000000d620204f14e330000000000000000",
    "1.50000000": "0x00010000010001000004278d00000000000c757094b7adf10000000000000000",
    "2.00000000": "0x000100000100010000041c5000000000000aca22c7fbd7718000000000000000",
    "3.00000000": "0x000100000100010000040c79000000000008cf4644e99c7f0000000000000000"
}

// Precomputed slot0 values for MOET/FUSDEV pool (18-vs-18 decimal tokens) at each yield price P
// MOET is token0 (0x2139... < 0xd069...), FUSDEV is token1
// When 1 FUSDEV share = P MOET in value: price_raw = 1/P (no decimal adjustment needed)
// sqrtPriceX96 = sqrt(1/P) * 2^96, tick = floor(ln(1/P) / ln(1.0001))
access(all) let moetFusdevPoolSlot0: {String: String} = {
    "1.00000000": "0x0001000001000100000000000000000000000001000000000000000000000000",
    "1.10000000": "0x000100000100010000fffc460000000000000000f4161fcec4f0e00000000000",
    "1.20000000": "0x000100000100010000fff8e00000000000000000e9b1e8c246e5f80000000000",
    "1.30000000": "0x000100000100010000fff5c00000000000000000e086dfd59e44200000000000",
    "1.50000000": "0x000100000100010000fff0290000000000000000d105eb806161f00000000000",
    "2.00000000": "0x000100000100010000ffe4ec0000000000000000b504f333f9de680000000000",
    "3.00000000": "0x000100000100010000ffd515000000000000000093cd3a2c8198e00000000000"
}

// Storage slots for pool token balances (keccak256(pad32(pool_address) || pad32(mapping_slot)))
// Needed to seed newly-created pools with token reserves so UniV3 quoter simulations succeed

// MOET/FUSDEV pool (0xeAac...) token balances
access(all) let moetBalanceSlotForMoetFusdevPool = "0xeb631df63d28ebb52410d4e0e8ba602d933d32e619cc3e8f012b6d5989a0db3f" // MOET slot 0
access(all) let fusdevBalanceSlotForMoetFusdevPool_v4 = "0xeb631df63d28ebb52410d4e0e8ba602d933d32e619cc3e8f012b6d5989a0db3f" // FUSDEV slot 0 (OZ v4)
access(all) let fusdevBalanceSlotForMoetFusdevPool_v5 = "0xc242bb614597bc3d10cac48621a2ba1278dae199e644854f03fd3d10887f2aa0" // FUSDEV OZ v5 namespaced

// PYUSD/FUSDEV pool (0x9196...) token balances
access(all) let pyusdBalanceSlotForPyusdFusdevPool = "0xb37abd8f52ad08129eee7bd9d19faa04af270f58d5e4bf98030f3b8d26f0d36a" // PYUSD slot 1
access(all) let fusdevBalanceSlotForPyusdFusdevPool_v4 = "0x8f45b3b204209c6d58d8339a7231d7d13a88e565f58c865db45429ac4e18d484" // FUSDEV slot 0
access(all) let fusdevBalanceSlotForPyusdFusdevPool_v5 = "0x17125c7263bafe7c28433900badc826b0db2df567cf3c81c53b2e2d60f7c5be3" // FUSDEV OZ v5

// PYUSD/WFLOW pool (0x0fdb...) token balances
access(all) let pyusdBalanceSlotForPyusdWflowPool = "0xba51025a1e274fc817d7caf4b0141ca0ea7ea8860bbdb8e694d652d68c24ee4a" // PYUSD slot 1
access(all) let wflowBalanceSlotForPyusdWflowPool = "0x57443b6217d89ca67db181e83f0c3d04eda874aeb7d2d349ddda6c94c1580758" // WFLOW slot 3 (WETH9: name=0, symbol=1, decimals=2, balanceOf=3)

// Create the missing Uniswap V3 pools needed for rebalancing
access(all) fun createRequiredPools(signer: Test.TestAccount) {
    log("\n=== CREATING REQUIRED UNISWAP V3 POOLS ===")

    // CORRECT MAINNET FACTORY ADDRESS (from flow.json mainnet deployment)
    let factory = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"
    let sqrtPriceX96_1_1 = "79228162514264337593543950336" // 2^96 for 1:1 price

    // Pool 1: PYUSD0/FUSDEV at fee 100 (0.01%) - CORRECTED ORDER
    log("Creating PYUSD0/FUSDEV pool...")
    var result = _executeTransaction(
        "transactions/create_uniswap_pool.cdc",
        [factory, pyusd0Address, morphoVaultAddress, UInt64(100), sqrtPriceX96_1_1],
        signer
    )
    if result.status == Test.ResultStatus.failed {
        log("PYUSD0/FUSDEV pool creation FAILED: ".concat(result.error?.message ?? "unknown"))
    } else {
        log("PYUSD0/FUSDEV pool tx succeeded")
    }

    // Pool 2: PYUSD0/FLOW at fee 3000 (0.3%)
    log("Creating PYUSD0/FLOW pool...")
    result = _executeTransaction(
        "transactions/create_uniswap_pool.cdc",
        [factory, pyusd0Address, flowEVMAddress, UInt64(3000), sqrtPriceX96_1_1],
        signer
    )
    if result.status == Test.ResultStatus.failed {
        log("PYUSD0/FLOW pool creation FAILED: ".concat(result.error?.message ?? "unknown"))
    } else {
        log("PYUSD0/FLOW pool tx succeeded")
    }

    // Pool 3: MOET/FUSDEV at fee 100 (0.01%)
    log("Creating MOET/FUSDEV pool...")
    result = _executeTransaction(
        "transactions/create_uniswap_pool.cdc",
        [factory, moetAddress, morphoVaultAddress, UInt64(100), sqrtPriceX96_1_1],
        signer
    )
    if result.status == Test.ResultStatus.failed {
        log("MOET/FUSDEV pool creation FAILED: ".concat(result.error?.message ?? "unknown"))
    } else {
        log("MOET/FUSDEV pool tx succeeded")
    }

    log("Pool creation transactions submitted")

    // CRITICAL: Seed ALL THREE POOLS with massive liquidity using vm.store
    // 
    // NOTE: On mainnet, MOET/FUSDEV pool doesn't exist, BUT there's a fallback path:
    //   MOET → PYUSD0 (Uniswap) → FUSDEV (ERC4626 deposit)
    // This means the bug CAN still occur on mainnet if MOET/PYUSD0 has liquidity.
    // 
    // We seed all three pools here to test the full amplification behavior with perfect liquidity.
    // The mainnet pools (PYUSD0/FUSDEV, PYUSD0/FLOW) exist but may have insufficient liquidity
    // at this fork block, so we seed them too.
    log("\n=== SEEDING ALL POOL LIQUIDITY WITH VM.STORE ===")

    // Pool addresses (using top-level constants)

    // Uniswap V3 pool storage layout:
    // slot 0: slot0 (packed: sqrtPriceX96, tick, observationIndex, etc.)
    // slot 1: feeGrowthGlobal0X128
    // slot 2: feeGrowthGlobal1X128  
    // slot 3: protocolFees (packed)
    // slot 4: liquidity (uint128)

    let liquiditySlot = "0x0000000000000000000000000000000000000000000000000000000000000004"
    // Set liquidity high enough that the 6% price-impact cap in UniswapV3SwapConnectors.getMaxInAmount()
    // can accommodate the full ~615 MOET borrow (need L*0.03 >= 615e18 → L >= ~2.05e22).
    // Using 1e26 for ample headroom. uint128 max is ~3.4e38.
    let liquidityValue = UInt256(1000000) * UInt256(1000000000000000000000) // 1e6 * 1e21 = 1e27
    let massiveLiquidity = "0x\(String.encodeHex(liquidityValue.toBigEndianBytes()))"

    // Seed PYUSD0/FUSDEV pool
    log("\n1. SEEDING PYUSD0/FUSDEV POOL (\(pyusd0FusdevPoolAddr))...")
    var seedResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0FusdevPoolAddr, liquiditySlot, massiveLiquidity],
        coaOwnerAccount
    )
    if seedResult.status == Test.ResultStatus.succeeded {
        log("   SUCCESS: PYUSD0/FUSDEV pool liquidity seeded")
    } else {
        panic("FAILED to seed PYUSD0/FUSDEV pool: ".concat(seedResult.error?.message ?? "unknown"))
    }

    // Seed PYUSD0/FLOW pool
    log("\n2. SEEDING PYUSD0/FLOW POOL (\(pyusd0FlowPoolAddr))...")
    seedResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0FlowPoolAddr, liquiditySlot, massiveLiquidity],
        coaOwnerAccount
    )
    if seedResult.status == Test.ResultStatus.succeeded {
        log("   SUCCESS: PYUSD0/FLOW pool liquidity seeded")
    } else {
        panic("FAILED to seed PYUSD0/FLOW pool: ".concat(seedResult.error?.message ?? "unknown"))
    }

    // Seed MOET/FUSDEV pool
    log("\n3. SEEDING MOET/FUSDEV POOL (\(moetFusdevPoolAddr))...")
    seedResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [moetFusdevPoolAddr, liquiditySlot, massiveLiquidity],
        coaOwnerAccount
    )
    if seedResult.status == Test.ResultStatus.succeeded {
        log("   SUCCESS: MOET/FUSDEV pool liquidity seeded")
    } else {
        panic("FAILED to seed MOET/FUSDEV pool: ".concat(seedResult.error?.message ?? "unknown"))
    }

    // Verify all pools have liquidity
    log("\n=== VERIFYING ALL POOLS HAVE LIQUIDITY ===")
    let poolAddresses = [pyusd0FusdevPoolAddr, pyusd0FlowPoolAddr, moetFusdevPoolAddr]
    let poolNames = ["PYUSD0/FUSDEV", "PYUSD0/FLOW", "MOET/FUSDEV"]

    var i = 0
    while i < poolAddresses.length {
        let poolStateResult = _executeScript(
            "scripts/check_pool_state.cdc",
            [poolAddresses[i]]
        )
        if poolStateResult.status == Test.ResultStatus.succeeded {
            let stateData = poolStateResult.returnValue as! {String: String}
            let liquidity = stateData["liquidity_data"] ?? "unknown"
            log("\(poolNames[i]): liquidity = \(liquidity)")

            if liquidity == "00000000000000000000000000000000000000000000000000000000000000" {
                panic("\(poolNames[i]) pool STILL has ZERO liquidity - vm.store failed!")
            }
        } else {
            panic("Failed to check \(poolNames[i]) pool state")
        }
        i = i + 1
    }

    log("\nAll pools verified and liquidity added")

    // CRITICAL: Seed token balances INTO the pools themselves
    // UniV3 swap simulation (used by quoter) requires the pool to hold actual tokens.
    // Without this, the topUpSource FUSDEV->MOET quote fails (pool can't transfer MOET it doesn't hold).
    log("\n=== SEEDING POOL TOKEN BALANCES (vm.store) ===")
    let massiveTokenBalanceValue = UInt256(1000000) * UInt256(1000000000000000000000) // 1e27
    let massiveTokenBalance = "0x\(String.encodeHex(massiveTokenBalanceValue.toBigEndianBytes()))"

    // MOET/FUSDEV pool: needs both MOET and FUSDEV
    log("  Seeding MOET/FUSDEV pool with MOET...")
    var tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [moetAddress, moetBalanceSlotForMoetFusdevPool, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("  Seeding MOET/FUSDEV pool with FUSDEV (trying slot 0)...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [morphoVaultAddress, fusdevBalanceSlotForMoetFusdevPool_v4, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("  Seeding MOET/FUSDEV pool with FUSDEV (trying OZ v5 namespaced slot)...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [morphoVaultAddress, fusdevBalanceSlotForMoetFusdevPool_v5, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    // PYUSD/FUSDEV pool: seed extra PYUSD and FUSDEV (mainnet pool, but price changed drastically)
    log("  Seeding PYUSD/FUSDEV pool with extra PYUSD...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [pyusd0Address, pyusdBalanceSlotForPyusdFusdevPool, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("  Seeding PYUSD/FUSDEV pool with extra FUSDEV (slot 0)...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [morphoVaultAddress, fusdevBalanceSlotForPyusdFusdevPool_v4, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("  Seeding PYUSD/FUSDEV pool with extra FUSDEV (OZ v5)...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [morphoVaultAddress, fusdevBalanceSlotForPyusdFusdevPool_v5, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    // PYUSD/WFLOW pool: seed extra PYUSD and WFLOW (price changed from ~$0.075 to $1)
    log("  Seeding PYUSD/WFLOW pool with extra PYUSD...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [pyusd0Address, pyusdBalanceSlotForPyusdWflowPool, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("  Seeding PYUSD/WFLOW pool with extra WFLOW...")
    tokenResult = _executeTransaction("transactions/store_storage_slot.cdc",
        [flowEVMAddress, wflowBalanceSlotForPyusdWflowPool, massiveTokenBalance], coaOwnerAccount)
    Test.expect(tokenResult, Test.beSucceeded())

    log("=== ALL POOL TOKEN BALANCES SEEDED ===\n")
}

// Seed the COA with massive token balances to enable swaps with minimal slippage
// This doesn't add liquidity to pools, but ensures the COA (which executes swaps) has tokens
access(all) fun seedCOAWithTokens(signer: Test.TestAccount) {
    log("\n=== SEEDING COA WITH MASSIVE TOKEN BALANCES ===")

    // Mint 1 trillion tokens (with appropriate decimals) to ensure deep liquidity for swaps
    // MOET: 18 decimals -> 1T = 1,000,000,000,000 * 10^18
    let moetAmount = UInt256(1000000000000) * UInt256(1000000000000000000)
    // PYUSD0: 6 decimals -> 1T = 1,000,000,000,000 * 10^6
    let pyusd0Amount = UInt256(1000000000000) * UInt256(1000000)
    // FLOW: 18 decimals -> 1T = 1,000,000,000,000 * 10^18
    let flowAmount = UInt256(1000000000000) * UInt256(1000000000000000000)

    log("Minting 1 trillion MOET to COA (slot \(moetBalanceSlotForCOA))...")
    var storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [moetAddress, moetBalanceSlotForCOA, "0x\(String.encodeHex(moetAmount.toBigEndianBytes()))"],
        signer
    )
    Test.expect(storeResult, Test.beSucceeded())

    log("Minting 1 trillion PYUSD0 to COA (slot \(pyusd0BalanceSlotForCOA))...")
    storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0Address, pyusd0BalanceSlotForCOA, "0x\(String.encodeHex(pyusd0Amount.toBigEndianBytes()))"],
        signer
    )
    Test.expect(storeResult, Test.beSucceeded())

    log("Minting 1 trillion FLOW to COA (slot \(flowBalanceSlotForCOA))...")
    storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [flowEVMAddress, flowBalanceSlotForCOA, "0x\(String.encodeHex(flowAmount.toBigEndianBytes()))"],
        signer
    )
    Test.expect(storeResult, Test.beSucceeded())

    log("COA token seeding complete - should enable near-1:1 swap rates")
}

// Set UniV3 pool slot0 (sqrtPriceX96 + tick) so DEX prices match our test assumptions:
// - PYUSD/WFLOW: always 1:1 value (1 PYUSD = 1 FLOW, BandOracle price)
// - PYUSD/FUSDEV: reflects current FUSDEV NAV so AutoBalancer rebalance swaps at oracle value
// - MOET/FUSDEV: same as PYUSD/FUSDEV (1 MOET = 1 PYUSD assumed)
access(all) fun setPoolPricesForYieldPrice(yieldPrice: UFix64, signer: Test.TestAccount) {
    log("\n=== SETTING UNIV3 POOL PRICES FOR YIELD PRICE \(yieldPrice) ===")

    // 1. PYUSD/WFLOW: always 1 PYUSD = 1 FLOW (constant)
    var result = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0FlowPoolAddr, uniV3Slot0StorageSlot, slot0_1to1_value_6vs18],
        signer
    )
    Test.expect(result, Test.beSucceeded())
    log("  PYUSD/WFLOW slot0 set to 1:1 value pricing")

    // 2. PYUSD/FUSDEV: 6-vs-18 decimal pool, price depends on current FUSDEV NAV
    let pyusdFusdevSlot0Val = pyusdFusdevPoolSlot0[yieldPrice.toString()]
        ?? panic("No precomputed PYUSD/FUSDEV slot0 for yield price ".concat(yieldPrice.toString()))

    result = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0FusdevPoolAddr, uniV3Slot0StorageSlot, pyusdFusdevSlot0Val],
        signer
    )
    Test.expect(result, Test.beSucceeded())
    log("  PYUSD/FUSDEV slot0 set for yield price \(yieldPrice)")

    // 3. MOET/FUSDEV: 18-vs-18 decimal pool, needs different sqrtPriceX96
    let moetFusdevSlot0Val = moetFusdevPoolSlot0[yieldPrice.toString()]
        ?? panic("No precomputed MOET/FUSDEV slot0 for yield price ".concat(yieldPrice.toString()))

    result = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [moetFusdevPoolAddr, uniV3Slot0StorageSlot, moetFusdevSlot0Val],
        signer
    )
    Test.expect(result, Test.beSucceeded())
    log("  MOET/FUSDEV slot0 set for yield price \(yieldPrice)")

    log("=== POOL PRICES SET SUCCESSFULLY ===\n")
}

// Set vault share price using an absolute multiplier against the stored baseline totalAssets.
// This avoids drift from rebalancing affecting the base between test steps.
// Manipulates both PYUSD0.balanceOf(vault) and vault._totalAssets to bypass maxRate capping.
access(all) fun setVaultSharePrice(vaultAddress: String, absoluteMultiplier: UFix64, signer: Test.TestAccount) {
    // Use baseline totalAssets captured at test start (immune to rebalancing side-effects)
    let base = baselineTotalAssets

    // Calculate target using UFix64 fixed-point math (UFix64 stores value * 10^8 internally)
    let multiplierBytes = absoluteMultiplier.toBigEndianBytes()
    var multiplierUInt64: UInt64 = 0
    for byte in multiplierBytes {
        multiplierUInt64 = (multiplierUInt64 << 8) + UInt64(byte)
    }
    let targetAssets = (base * UInt256(multiplierUInt64)) / UInt256(100000000)

    log("[VM.STORE] Setting vault price to \(absoluteMultiplier.toString())x baseline (totalAssets: \(base.toString()) -> \(targetAssets.toString()))")

    // 1. Set PYUSD0.balanceOf(vault)
    var storeResult = _executeTransaction(
        "transactions/store_storage_slot.cdc",
        [pyusd0Address, pyusd0BalanceSlotForVault, "0x\(String.encodeHex(targetAssets.toBigEndianBytes()))"],
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
    let blockResult = _executeScript("scripts/get_current_block_timestamp.cdc", [])
    let currentTimestamp = blockResult.status == Test.ResultStatus.succeeded 
        ? UInt64(blockResult.returnValue as! UFix64)
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

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means it's a deposit (collateral)
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

// Enhanced diagnostic precision tracking function with full call stack tracing
access(all) fun performDiagnosticPrecisionTrace(
    yieldVaultID: UInt64,
    pid: UInt64,
    yieldPrice: UFix64,
    expectedValue: UFix64,
    userAddress: Address
) {
    // Get position ground truth
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    var flowAmount: UFix64 = 0.0
    
    for balance in positionDetails.balances {
        if balance.vaultType.identifier == flowTokenIdentifier { 
            if balance.direction.rawValue == 0 {  // Credit
                flowAmount = balance.balance
            }
        }
    }
    
    // Values at different layers
    let positionValue = flowAmount * 1.0  // Flow price = 1.0 in Scenario 2
    let yieldVaultValue = getYieldVaultBalance(address: userAddress, yieldVaultID: yieldVaultID) ?? 0.0

    // Calculate drifts with proper sign handling
    let yieldVaultDriftAbs = yieldVaultValue > expectedValue ? yieldVaultValue - expectedValue : expectedValue - yieldVaultValue
    let yieldVaultDriftSign = yieldVaultValue > expectedValue ? "+" : "-"
    let positionDriftAbs = positionValue > expectedValue ? positionValue - expectedValue : expectedValue - positionValue
    let positionDriftSign = positionValue > expectedValue ? "+" : "-"
    let yieldVaultVsPositionAbs = yieldVaultValue > positionValue ? yieldVaultValue - positionValue : positionValue - yieldVaultValue
    let yieldVaultVsPositionSign = yieldVaultValue > positionValue ? "+" : "-"
    
    // Enhanced logging with intermediate values
    log("\n+----------------------------------------------------------------+")
    log("|          PRECISION DRIFT DIAGNOSTIC - Yield Price \(yieldPrice)         |")
    log("+----------------------------------------------------------------+")
    log("| Layer          | Value          | Drift         | % Drift      |")
    log("|----------------|----------------|---------------|--------------|")
    log("| Position       | \(formatValue(positionValue)) | \(positionDriftSign)\(formatValue(positionDriftAbs)) | \(positionDriftSign)\(formatPercent(positionDriftAbs / expectedValue))% |")
    log("| YieldVault Balance   | \(formatValue(yieldVaultValue)) | \(yieldVaultDriftSign)\(formatValue(yieldVaultDriftAbs)) | \(yieldVaultDriftSign)\(formatPercent(yieldVaultDriftAbs / expectedValue))% |")
    log("| Expected       | \(formatValue(expectedValue)) | ------------- | ------------ |")
    log("|----------------|----------------|---------------|--------------|")
    log("| YieldVault vs Position: \(yieldVaultVsPositionSign)\(formatValue(yieldVaultVsPositionAbs))                                   |")
    log("+----------------------------------------------------------------+")
    
    // Log intermediate calculation values
    log("\n== INTERMEDIATE VALUES TRACE:")
    
    // Log position balance details
    log("- Position Balance Details:")
    log("  * Flow Amount (trueBalance): \(flowAmount)")
    
    // Skip the problematic UInt256 conversion entirely to avoid overflow
    log("- Expected Value Analysis:")
    log("  * Expected UFix64: \(expectedValue)")
    
    // Log precision loss summary without complex calculations
    log("- Precision Loss Summary:")
    log("  * Position vs Expected: \(positionDriftSign)\(formatValue(positionDriftAbs)) (\(positionDriftSign)\(formatPercent(positionDriftAbs / expectedValue))%)")
    log("  * YieldVault vs Expected: \(yieldVaultDriftSign)\(formatValue(yieldVaultDriftAbs)) (\(yieldVaultDriftSign)\(formatPercent(yieldVaultDriftAbs / expectedValue))%)")
    log("  * Additional YieldVault Loss: \(yieldVaultVsPositionSign)\(formatValue(yieldVaultVsPositionAbs))")

    // Warning if significant drift
    if yieldVaultDriftAbs > 0.00000100 {
        log("\n⚠️  WARNING: Significant precision drift detected!")
    }
}

access(all)
fun setup() {
    var err = Test.deployContract(name: "EVM", path: "./contracts/MockEVM.cdc", arguments: [])
    Test.expect(err, Test.beNil())

    err = Test.deployContract(name: "ERC4626PriceOracles", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/evm/ERC4626PriceOracles.cdc", arguments: [])
    Test.expect(err, Test.beNil())

    // Create the missing Uniswap V3 pools
    createRequiredPools(signer: coaOwnerAccount)

    // Seed COA with massive token balances to enable low-slippage swaps
    seedCOAWithTokens(signer: whaleFlowAccount)

    // Set all pool prices to 1:1 value at initial yield price 1.0
    // This overrides mainnet sqrtPriceX96 (which reflects real FLOW price ~$0.075)
    // with our test assumption of 1 PYUSD = 1 FLOW and 1 FUSDEV = 1 PYUSD
    setPoolPricesForYieldPrice(yieldPrice: 1.0, signer: coaOwnerAccount)

    // Verify pools exist (either pre-existing or just created)
    log("\n=== VERIFYING POOL EXISTENCE ===")
    let verifyResult = _executeScript("scripts/verify_pool_creation.cdc", [])
    Test.expect(verifyResult, Test.beSucceeded())
    let poolData = verifyResult.returnValue as! {String: String}
    log("PYUSD0/FUSDEV fee100: ".concat(poolData["PYUSD0_FUSDEV_fee100"] ?? "not found"))
    log("PYUSD0/FLOW fee3000: ".concat(poolData["PYUSD0_FLOW_fee3000"] ?? "not found"))
    log("MOET/FUSDEV fee100: ".concat(poolData["MOET_FUSDEV_fee100"] ?? "not found"))

	// BandOracle is only used for FLOW price for FCM collateral.
    let symbolPrices: {String: UFix64}   = {
        "FLOW": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	// service account does not have enough flow to "mint"
	// var mintFlowResult = mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)

	mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    // service account does not have enough flow to "mint"
	// mintFlowResult = mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)

	// Capture baseline and NORMALIZE so vault share price starts at exactly 1.0.
	// vault_price = totalAssets * 1e12 / totalSupply, so for price=1.0: totalAssets = totalSupply / 1e12
	// This ensures pool prices (set for yield P) match vault oracle prices (baselinePrice * P = 1.0 * P = P).
	let priceResult = _executeScript("scripts/get_erc4626_vault_price.cdc", [morphoVaultAddress])
	Test.expect(priceResult, Test.beSucceeded())
	let priceData = priceResult.returnValue as! {String: String}
	let originalTotalAssets = UInt256.fromString(priceData["totalAssets"]!)!
	let totalSupply = UInt256.fromString(priceData["totalSupply"]!)!
	let originalPrice = totalSupply > UInt256(0)
		? (originalTotalAssets * UInt256(1000000000000)) / totalSupply
		: UInt256(0)
	log("[SETUP] Original vault: totalAssets=\(originalTotalAssets.toString()), totalSupply=\(totalSupply.toString()), price=\(originalPrice.toString())")

	// Normalize: set baseline so that multiplier=1.0 gives share price = exactly 1.0
	baselineTotalAssets = totalSupply / UInt256(1000000000000) // 1e12
	log("[SETUP] Normalized baseline totalAssets: \(baselineTotalAssets.toString()) (price will be 1.0)")

	// Apply the normalized price to the vault so it's consistent with pool prices (set to 1.0 above)
	setVaultSharePrice(vaultAddress: morphoVaultAddress, absoluteMultiplier: 1.0, signer: coaOwnerAccount)

	snapshot = getCurrentBlockHeight()
}

/// Logs full position details (all balances with direction, health, etc.)
access(all)
fun logPositionDetails(label: String, pid: UInt64) {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    log("\n--- Position Details (\(label)) pid=\(pid) ---")
    log("  health: \(positionDetails.health)")
    log("  defaultTokenAvailableBalance: \(positionDetails.defaultTokenAvailableBalance)")
    for balance in positionDetails.balances {
        let direction = balance.direction.rawValue == 0 ? "CREDIT(collateral)" : "DEBIT(debt)"
        log("  [\(direction)] \(balance.vaultType.identifier): \(balance.balance)")
    }
    log("--- End Position Details ---")
}

access(all)
fun test_RebalanceYieldVaultScenario2() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0

	let user = Test.createAccount()

	let yieldPriceIncreases = [1.1, 1.2, 1.3, 1.5, 2.0, 3.0]
	let expectedFlowBalance = [
	1061.53846154,
	1120.92522862,
	1178.40857368,
	1289.97388243,
	1554.58390959,
	2032.91742023
	]

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

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

	var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("[TEST] Initial yield vault balance: \(yieldVaultBalance ?? 0.0)")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

	for index, yieldTokenPrice in yieldPriceIncreases {
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice): \(yieldVaultBalance ?? 0.0)")

		// Set vault price using absolute multiplier against baseline (immune to rebalancing side-effects)
        setVaultSharePrice(vaultAddress: morphoVaultAddress, absoluteMultiplier: yieldTokenPrice, signer: user)
        setPoolPricesForYieldPrice(yieldPrice: yieldTokenPrice, signer: coaOwnerAccount)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: false, beFailed: false)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after yield price \(yieldTokenPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// Perform comprehensive diagnostic precision trace
		performDiagnosticPrecisionTrace(
			yieldVaultID: yieldVaultIDs![0],
			pid: pid,
			yieldPrice: yieldTokenPrice,
			expectedValue: expectedFlowBalance[index],
			userAddress: user.address
		)

		// Get Flow collateral from position
		let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
		let flowCollateralValue = flowCollateralAmount * 1.0  // Flow price remains at 1.0
		
		// Detailed precision comparison
		let actualYieldVaultBalance = yieldVaultBalance ?? 0.0
		let expectedBalance = expectedFlowBalance[index]
		
		// Calculate differences
		let yieldVaultDiff = actualYieldVaultBalance > expectedBalance ? actualYieldVaultBalance - expectedBalance : expectedBalance - actualYieldVaultBalance
		let yieldVaultSign = actualYieldVaultBalance > expectedBalance ? "+" : "-"
		let yieldVaultPercentDiff = (yieldVaultDiff / expectedBalance) * 100.0

		let positionDiff = flowCollateralValue > expectedBalance ? flowCollateralValue - expectedBalance : expectedBalance - flowCollateralValue
		let positionSign = flowCollateralValue > expectedBalance ? "+" : "-"
		let positionPercentDiff = (positionDiff / expectedBalance) * 100.0

		let yieldVaultVsPositionDiff = actualYieldVaultBalance > flowCollateralValue ? actualYieldVaultBalance - flowCollateralValue : flowCollateralValue - actualYieldVaultBalance
		let yieldVaultVsPositionSign = actualYieldVaultBalance > flowCollateralValue ? "+" : "-"
		
		log("\n=== PRECISION COMPARISON for Yield Price \(yieldTokenPrice) ===")
		log("Expected Value:         \(expectedBalance)")
		log("Actual YieldVault Balance:    \(actualYieldVaultBalance)")
		log("Flow Position Value:    \(flowCollateralValue)")
		log("Flow Position Amount:   \(flowCollateralAmount) tokens")
		log("")
		log("YieldVault vs Expected:       \(yieldVaultSign)\(yieldVaultDiff) (\(yieldVaultSign)\(yieldVaultPercentDiff)%)")
		log("Position vs Expected:   \(positionSign)\(positionDiff) (\(positionSign)\(positionPercentDiff)%)")
		log("YieldVault vs Position:       \(yieldVaultVsPositionSign)\(yieldVaultVsPositionDiff)")
		log("===============================================\n")

        let percentToleranceCheck = equalAmounts(a: yieldVaultPercentDiff, b: 0.0, tolerance: forkedPercentTolerance)
        Test.assert(percentToleranceCheck, message: "Percent difference \(yieldVaultPercentDiff)% is not within tolerance \(forkedPercentTolerance)%")
        log("Percent difference \(yieldVaultPercentDiff)% is within tolerance \(forkedPercentTolerance)%")
	}

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")

	Test.assert(
		(flowBalanceAfter-flowBalanceBefore) > 0.1,
		message: "Expected user's Flow balance after rebalance to be more than zero but got \(flowBalanceAfter)"
	)
}

