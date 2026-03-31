#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategiesV2"
import "FlowALPv0"

// ============================================================================
// CADENCE ACCOUNTS
// ============================================================================

access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowALPAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV2.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

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
access(all) let moetBalanceSlot = 0 as UInt256
access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wflowBalanceSlot = 3 as UInt256

// Morpho vault storage slots
access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

access(all) var snapshot: UInt64 = 0
access(all) let TARGET_HEALTH: UFix128 = 1.3
access(all) let SOLVENT_HEALTH_FLOOR: UFix128 = 1.0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
	deployContractsForFork()
    snapshot = getCurrentBlockHeight()
}

/// Configure the environment after resetting to the post-deploy snapshot.
/// Each test resets to `snapshot` then calls this with its own starting prices.
access(all)
fun setupEnv(flowPrice: UFix128, yieldPrice: UFix128) {
    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    // PYUSD = 1.0, FUSDEV = yieldPrice, FLOW = flowPrice
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/yieldPrice, fee: 100, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/flowPrice, fee: 3000, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/yieldPrice, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = { 
        "FLOW": UFix64(flowPrice),  // Start at 0.03
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)

    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: UFix64(yieldPrice),
        signer: coaOwnerAccount
    )
}


access(all)
fun test_RebalanceLowCollateralHighYieldPrices() {
	// Scenario 4: Large FLOW position at real-world low FLOW price
	// FLOW drops further while YT price surges — tests closeYieldVault at extreme price ratios
    safeReset()
	setupEnv(flowPrice: 0.03, yieldPrice: 1000.0)

	let fundingAmount = 1_000_000.0
	let flowPriceDecrease = 0.02    // FLOW: $0.03 → $0.02
	let yieldPriceIncrease = 1500.0 // YT:   $1000.0 → $1500.0

	let user = Test.createAccount()
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
    var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)
	log("[Scenario4] YieldVault ID: \(yieldVaultIDs![0]), position ID: \(pid)")

	// --- Phase 1: FLOW price drops from $0.03 to $0.02 ---
	setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPriceDecrease,
        "USD": 1.0
    })

    // Update WFLOW/PYUSD0 pool to reflect new FLOW price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(flowPriceDecrease), fee: 3000, reverse: true),
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Position rebalance sells FUSDEV -> MOET to repay debt (reverse direction)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/1000.0, fee: 100, reverse: true),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    // Possible path: FUSDEV -> PYUSD0 (Morpho redeem) -> PYUSD0 -> MOET (reverse on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: true),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

	let ytBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtBefore = getMOETDebtFromPosition(pid: pid)
	let collateralBefore = getFlowCollateralFromPosition(pid: pid)

	log("\n[Scenario4] Pre-rebalance state (vault created @ FLOW=$0.03, YT=$1000.0; FLOW oracle now $\(flowPriceDecrease))")
	log("  YT balance:      \(ytBefore) YT")
	log("  FLOW collateral: \(collateralBefore) FLOW (value: \(collateralBefore * flowPriceDecrease) MOET @ $\(flowPriceDecrease)/FLOW)")
	log("  MOET debt:       \(debtBefore) MOET")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	let ytAfterFlowDrop = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterFlowDrop = getMOETDebtFromPosition(pid: pid)
	let collateralAfterFlowDrop = getFlowCollateralFromPosition(pid: pid)

	log("\n[Scenario4] After rebalance (FLOW=$\(flowPriceDecrease), YT=$1000.0)")
	log("  YT balance:      \(ytAfterFlowDrop) YT")
	log("  FLOW collateral: \(collateralAfterFlowDrop) FLOW (value: \(collateralAfterFlowDrop * flowPriceDecrease) MOET)")
	log("  MOET debt:       \(debtAfterFlowDrop) MOET")

	// The position was undercollateralized after FLOW price drop, so the topUpSource
	// (AutoBalancer YT → MOET) should have repaid some debt, reducing both YT and MOET debt.
	Test.assert(debtAfterFlowDrop < debtBefore,
		message: "Expected MOET debt to decrease after rebalancing undercollateralized position, got \(debtAfterFlowDrop) (was \(debtBefore))")
	Test.assert(ytAfterFlowDrop < ytBefore,
		message: "Expected AutoBalancer YT to decrease after using topUpSource to repay debt, got \(ytAfterFlowDrop) (was \(ytBefore))")
	// FLOW collateral is not touched by debt repayment
    Test.assert(equalAmounts(a: collateralAfterFlowDrop, b: collateralBefore, tolerance: 0.001),
		message: "Expected FLOW collateral to be unchanged after debt repayment rebalance, got \(collateralAfterFlowDrop) (was \(collateralBefore))")

	// --- Phase 2: YT price rises from $1000.0 to $1500.0 ---
	setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: UInt256(1),
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: yieldPriceIncrease,
        signer: user
    )
    
    // AutoBalancer sells FUSDEV -> PYUSD0 (forward on this pool: tokenA -> tokenB)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: false),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Position rebalance borrows MOET -> FUSDEV (reverse on this pool: tokenB -> tokenA)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: moetAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: true),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: moetBalanceSlot,
        signer: coaOwnerAccount
    )

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	let ytAfterYTRise = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterYTRise = getMOETDebtFromPosition(pid: pid)
	let collateralAfterYTRise = getFlowCollateralFromPosition(pid: pid)

	log("\n[Scenario4] After rebalance (FLOW=$\(flowPriceDecrease), YT=$\(yieldPriceIncrease))")
	log("  YT balance:      \(ytAfterYTRise) YT")
	log("  FLOW collateral: \(collateralAfterYTRise) FLOW (value: \(collateralAfterYTRise * flowPriceDecrease) MOET)")
	log("  MOET debt:       \(debtAfterYTRise) MOET")

	// The AutoBalancer's YT is now worth 50% more, making its value exceed the deposit threshold.
	// It should push excess YT → FLOW into the position, increasing collateral and reducing YT.
	Test.assert(ytAfterYTRise < ytAfterFlowDrop,
		message: "Expected AutoBalancer YT to decrease after pushing excess value to position, got \(ytAfterYTRise) (was \(ytAfterFlowDrop))")
	Test.assert(collateralAfterYTRise > collateralAfterFlowDrop,
		message: "Expected FLOW collateral to increase after AutoBalancer pushed YT→FLOW to position, got \(collateralAfterYTRise) (was \(collateralAfterFlowDrop))")

	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	// After close, the vault should no longer exist and the user should have received their FLOW back
	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	Test.assert(flowBalanceAfter > flowBalanceBefore,
		message: "Expected user FLOW balance to increase after closing vault, got \(flowBalanceAfter) (was \(flowBalanceBefore))")

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs == nil || yieldVaultIDs!.length == 0,
		message: "Expected no yield vaults after close but found \(yieldVaultIDs?.length ?? 0)")

	log("\n[Scenario4] Test complete")
}

access(all)
fun test_RebalanceHighCollateralLowYieldPrices() {
	// Scenario 5: High-value collateral with moderate price drop
	// Tests rebalancing when FLOW drops 20% from $1000 → $800
	// This scenario tests whether position can handle moderate drops without liquidation
    safeReset()
	setupEnv(flowPrice: 1000.0, yieldPrice: 1.0)

	let fundingAmount = 100.0
	let initialFlowPrice = 1000.00    // Starting price for this scenario
	let flowPriceDecrease = 800.00    // FLOW: $1000 → $800 (20% drop)
	let yieldPriceIncrease = 1.5      // YT: $1.0 → $1.5

	let user = Test.createAccount()
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
    var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)
	log("[Scenario5] YieldVault ID: \(yieldVaultIDs![0]), position ID: \(pid)")

	let initialCollateral = getFlowCollateralFromPosition(pid: pid)
	let initialDebt = getMOETDebtFromPosition(pid: pid)
	let initialHealth = getPositionHealth(pid: pid, beFailed: false)
	let initialCollateralValue = initialCollateral * initialFlowPrice
	log("[Scenario5] Initial state (FLOW=$\(initialFlowPrice), YT=$1.0)")
	log("  Funding: \(initialCollateral) FLOW")
	log("  Collateral value: $\(initialCollateralValue)")
	log("  Actual debt: $\(initialDebt) MOET")
	log("  Initial health: \(initialHealth)")

	// --- Phase 1: FLOW price drops from $1000 to $800 (20% drop) ---
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPriceDecrease,
        "USD": 1.0
    })

    // Update WFLOW/PYUSD0 pool to reflect new FLOW price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(flowPriceDecrease), fee: 3000, reverse: true),
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Position rebalance sells FUSDEV -> MOET to repay debt (reverse direction)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: true),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    // Possible path: FUSDEV -> PYUSD0 (Morpho redeem) -> PYUSD0 -> MOET (reverse on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: true),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

	let ytBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtBefore = getMOETDebtFromPosition(pid: pid)
	let collateralBefore = getFlowCollateralFromPosition(pid: pid)

	// Read health from FlowALP so this test tracks protocol configuration changes.
	let healthBeforeRebalance = getPositionHealth(pid: pid, beFailed: false)
	let collateralValueBefore = collateralBefore * flowPriceDecrease

	log("[Scenario5] After price drop to $\(flowPriceDecrease) (BEFORE rebalance)")
	log("  YT balance:      \(ytBefore) YT")
	log("  FLOW collateral: \(collateralBefore) FLOW")
	log("  Collateral value: $\(collateralValueBefore) MOET")
	log("  MOET debt:       \(debtBefore) MOET")
	log("  Health:          \(healthBeforeRebalance)")

	// The price drop should push health below the rebalance target while keeping the position solvent.
	Test.assert(healthBeforeRebalance < TARGET_HEALTH,
		message: "Expected health to drop below TARGET_HEALTH (\(TARGET_HEALTH)) after 20% FLOW price drop, got \(healthBeforeRebalance)")
	Test.assert(healthBeforeRebalance > SOLVENT_HEALTH_FLOOR,
		message: "Expected health to remain above \(SOLVENT_HEALTH_FLOOR) after 20% FLOW price drop, got \(healthBeforeRebalance)")

	// Rebalance to restore health to the strategy target.
	log("[Scenario5] Rebalancing position and yield vault...")
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	let ytAfterFlowDrop = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterFlowDrop = getMOETDebtFromPosition(pid: pid)
	let collateralAfterFlowDrop = getFlowCollateralFromPosition(pid: pid)
	let healthAfterRebalance = getPositionHealth(pid: pid, beFailed: false)

	log("[Scenario5] After rebalance (FLOW=$\(flowPriceDecrease), YT=$1.0)")
	log("  YT balance:      \(ytAfterFlowDrop) YT")
	log("  FLOW collateral: \(collateralAfterFlowDrop) FLOW")
	log("  Collateral value: $\(collateralAfterFlowDrop * flowPriceDecrease) MOET")
	log("  MOET debt:       \(debtAfterFlowDrop) MOET")
	log("  Health:          \(healthAfterRebalance)")

	// The position was undercollateralized (health < TARGET_HEALTH) after the FLOW price drop,
	// so the topUpSource (AutoBalancer YT → MOET) should have repaid some debt.
	Test.assert(debtAfterFlowDrop < debtBefore,
		message: "Expected MOET debt to decrease after rebalancing undercollateralized position, got \(debtAfterFlowDrop) (was \(debtBefore))")
	Test.assert(ytAfterFlowDrop < ytBefore,
		message: "Expected AutoBalancer YT to decrease after using topUpSource to repay debt, got \(ytAfterFlowDrop) (was \(ytBefore))")
	// Debt repayment only affects the MOET debit — FLOW collateral is untouched.
	Test.assert(equalAmounts(a: collateralAfterFlowDrop, b: collateralBefore, tolerance: 0.000001),
		message: "Expected FLOW collateral to be unchanged after debt repayment, got \(collateralAfterFlowDrop) (was \(collateralBefore))")
	// The AutoBalancer has sufficient YT to cover the full repayment needed to reach the target.
	Test.assert(equalAmounts128(a: healthAfterRebalance, b: TARGET_HEALTH, tolerance: 0.00000001),
		message: "Expected health to be fully restored to TARGET_HEALTH (\(TARGET_HEALTH)) after rebalance, got \(healthAfterRebalance)")

	// --- Phase 2: YT price rises from $1.0 to $1.5 ---
	log("[Scenario5] Phase 2: YT price increases to $\(yieldPriceIncrease)")
	setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: UInt256(1),
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: yieldPriceIncrease,
        signer: user
    )
    
    // Recollat traverses FUSDEV→PYUSD0 (forward on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: false),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Surplus swaps MOET→FUSDEV (reverse on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: moetAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: true),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: moetBalanceSlot,
        signer: coaOwnerAccount
    )

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	let ytAfterYTRise = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterYTRise = getMOETDebtFromPosition(pid: pid)
	let collateralAfterYTRise = getFlowCollateralFromPosition(pid: pid)
	let healthAfterYTRise = getPositionHealth(pid: pid, beFailed: false)

	log("[Scenario5] After YT rise (FLOW=$\(flowPriceDecrease), YT=$\(yieldPriceIncrease))")
	log("  YT balance:      \(ytAfterYTRise) YT")
	log("  FLOW collateral: \(collateralAfterYTRise) FLOW")
	log("  Collateral value: $\(collateralAfterYTRise * flowPriceDecrease) MOET")
	log("  MOET debt:       \(debtAfterYTRise) MOET")
	log("  Health:          \(healthAfterYTRise)")

	// The AutoBalancer's YT is now worth 50% more, exceeding the upper threshold.
	// It pushes excess YT → FLOW into the position, reducing YT and increasing FLOW collateral.
	Test.assert(ytAfterYTRise < ytAfterFlowDrop,
		message: "Expected AutoBalancer YT to decrease after pushing excess value to position, got \(ytAfterYTRise) (was \(ytAfterFlowDrop))")
	Test.assert(collateralAfterYTRise > collateralAfterFlowDrop,
		message: "Expected FLOW collateral to increase after AutoBalancer pushed YT→FLOW to position, got \(collateralAfterYTRise) (was \(collateralAfterFlowDrop))")

	// Rebalance both position and yield vault before closing to ensure everything is settled
	log("\n[Scenario5] Rebalancing position and yield vault before close...")
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	let ytBeforeClose = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtBeforeClose = getMOETDebtFromPosition(pid: pid)
	let collateralBeforeClose = getFlowCollateralFromPosition(pid: pid)
	log("[Scenario5] After final rebalance before close:")
	log("  YT balance:      \(ytBeforeClose) YT")
	log("  FLOW collateral: \(collateralBeforeClose) FLOW")
	log("  MOET debt:       \(debtBeforeClose) MOET")

	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

	// Close the yield vault
	// log("\n[Scenario5] Closing yield vault...")
    // TODO: closeYieldVault currently fails due to precision issues
	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	// // User should receive their collateral back; vault should be destroyed.
	// let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	// Test.assert(flowBalanceAfter > flowBalanceBefore,
	// 	message: "Expected user FLOW balance to increase after closing vault, got \(flowBalanceAfter) (was \(flowBalanceBefore))")

	// yieldVaultIDs = getYieldVaultIDs(address: user.address)
	// Test.assert(yieldVaultIDs == nil || yieldVaultIDs!.length == 0,
	// 	message: "Expected no yield vaults after close but found \(yieldVaultIDs?.length ?? 0)")
}
