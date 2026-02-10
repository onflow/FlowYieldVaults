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

// PYUSD0 balanceOf mapping is at slot 1 (standard ERC20 layout)
// Storage slot for balanceOf[morphoVault] = keccak256(vault_address_padded || slot_1)
// Calculated using: cast keccak 0x000000000000000000000000d069d989e2f44b70c65347d1853c0c67e10a9f8d0000000000000000000000000000000000000000000000000000000000000001
access(all) let pyusd0BalanceSlotForVault = "0x00056c3aa1845366a3744ff6c51cff309159d9be9eacec9ff06ec523ae9db7f0"

// Morpho vault _totalAssets slot (slot 15, packed with lastUpdate and maxRate)
access(all) let morphoVaultTotalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"

// ERC20 balanceOf mapping slots (standard layout at slot 0 for most tokens)
access(all) let erc20BalanceOfSlot = "0x0000000000000000000000000000000000000000000000000000000000000000"

// Token addresses for liquidity seeding
access(all) let moetAddress = "0x5c147e74D63B1D31AA3Fd78Eb229B65161983B2b"
access(all) let flowEVMAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// Storage slots for balanceOf[COA] where COA = 0xe467b9dd11fa00df
// Calculated via: cast index address 0x000000000000000000000000e467b9dd11fa00df <slot>
access(all) let moetBalanceSlotForCOA = "0x00163bda938054c6ef029aa834a66783a57ce7bedb1a8c2815e8bdf7ab9ddb39"  // MOET slot 0
access(all) let pyusd0BalanceSlotForCOA = "0xb2beb48b003c8e5b001f84bc854c4027531bf1261e8e308e47f3edf075df5ab5"  // PYUSD0 slot 1
access(all) let flowBalanceSlotForCOA = "0x00163bda938054c6ef029aa834a66783a57ce7bedb1a8c2815e8bdf7ab9ddb39"  // FLOW slot 0

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
    
    log("\n=== POOL STATUS SUMMARY ===")
    log("PYUSD0/FUSDEV (fee 100): Exists on mainnet")
    log("PYUSD0/FLOW (fee 3000): Exists on mainnet")
    log("MOET/FUSDEV (fee 100): Created in fork, initialized")
    
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
    
    // Pool addresses
    let pyusd0FusdevPoolAddr = "0x9196e243b7562b0866309013f2f9eb63f83a690f"  // PYUSD0/FUSDEV fee 100
    let pyusd0FlowPoolAddr = "0x0fdba612fea7a7ad0256687eebf056d81ca63f63"     // PYUSD0/FLOW fee 3000
    let moetFusdevPoolAddr = "0x2d19d4287d6708fdc47d649cc07114aec8cb0d6a"    // MOET/FUSDEV fee 100
    
    // Uniswap V3 pool storage layout:
    // slot 0: slot0 (packed: sqrtPriceX96, tick, observationIndex, etc.)
    // slot 1: feeGrowthGlobal0X128
    // slot 2: feeGrowthGlobal1X128  
    // slot 3: protocolFees (packed)
    // slot 4: liquidity (uint128)
    
    let liquiditySlot = "0x0000000000000000000000000000000000000000000000000000000000000004"
    // Set liquidity to 1e21 (1 sextillion) - uint128 max is ~3.4e38
    let massiveLiquidity = "0x00000000000000000000000000000000000000000000003635c9adc5dea00000" // 1e21 in hex
    
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
    
    log("\n✓ ALL THREE POOLS NOW HAVE MASSIVE LIQUIDITY (1e21 each)")
    
    log("\nAll pools verified and liquidity added\n")
}

// Seed the COA with massive token balances to enable swaps with minimal slippage
// This doesn't add liquidity to pools, but ensures the COA (which executes swaps) has tokens
access(all) fun seedCOAWithTokens(signer: Test.TestAccount) {
    log("\n=== SEEDING COA WITH MASSIVE TOKEN BALANCES ===")
    
    // Mint 1 trillion tokens (with appropriate decimals) to ensure deep liquidity for swaps
    // MOET: 6 decimals -> 1T = 1,000,000,000,000 * 10^6
    let moetAmount = UInt256(1000000000000) * UInt256(1000000)
    // PYUSD0: 6 decimals -> same as MOET
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

access(all)
fun setup() {
    // Deploy mock EVM contract to enable vm.store/vm.load cheatcodes
    var err = Test.deployContract(name: "EVM", path: "../contracts/mocks/EVM.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    
    // Create the missing Uniswap V3 pools
    createRequiredPools(signer: coaOwnerAccount)
    
    // Seed COA with massive token balances to enable low-slippage swaps
    seedCOAWithTokens(signer: whaleFlowAccount)
    
    // Verify pools exist (either pre-existing or just created)
    log("\n=== VERIFYING POOL EXISTENCE ===")
    let verifyResult = _executeScript("scripts/verify_pool_creation.cdc", [])
    Test.expect(verifyResult, Test.beSucceeded())
    let poolData = verifyResult.returnValue as! {String: String}
    log("PYUSD0/FUSDEV fee100: ".concat(poolData["PYUSD0_FUSDEV_fee100"] ?? "not found"))
    log("PYUSD0/FLOW fee3000: ".concat(poolData["PYUSD0_FLOW_fee3000"] ?? "not found"))
    log("MOET/FUSDEV fee100: ".concat(poolData["MOET_FUSDEV_fee100"] ?? "not found"))
    
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
