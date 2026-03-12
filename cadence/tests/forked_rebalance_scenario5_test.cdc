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

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means it's a deposit (collateral)
            if balance.direction == FlowALPv0.BalanceDirection.Credit {
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
            // Debit means it's borrowed (debt)
            if balance.direction == FlowALPv0.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}

access(all)
fun setup() {
	deployContractsForFork()

	// Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    // PYUSD/FUSDEV= 1.0, FLOW = 1000
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/1000.0, fee: 3000, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: false),
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
        "FLOW": 1000.0,  // Start at 1000
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

access(all)
fun test_RebalanceYieldVaultScenario5() {
	// Scenario 5: High-value collateral with moderate price drop
	// Tests rebalancing when FLOW drops 20% from $1000 → $800
	// This scenario tests whether position can handle moderate drops without liquidation

	let fundingAmount = 100.0
	let initialFlowPrice = 1000.00    // Setup price
	let flowPriceDecrease = 800.00    // FLOW: $1000 → $800 (20% drop)
	let yieldPriceIncrease = 1.5      // YT: $1.0 → $1.5

    // expected final values derived from original scenario
    let expectedYieldTokenValues = [42919.13224896]
    let expectedFlowCollateralValues = [130.76923107]
    let expectedDebtValues = [64378.69837343]

	let user = Test.createAccount()
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1 price
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: 1.0,
        signer: user
    )

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

	// Calculate initial health
	let initialCollateralValue = fundingAmount * initialFlowPrice
	let initialDebt = initialCollateralValue * 0.8 / 1.1  // CF=0.8, minHealth=1.1
	let initialHealth = (fundingAmount * 0.8 * initialFlowPrice) / initialDebt
	log("[Scenario5] Initial state (FLOW=$\(initialFlowPrice), YT=$1.0)")
	log("  Funding: \(fundingAmount) FLOW")
	log("  Collateral value: $\(initialCollateralValue)")
	log("  Expected debt: $\(initialDebt) MOET")
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

	// Calculate health before rebalance (avoid division by zero)
	let healthBeforeRebalance = debtBefore > 0.0
		? (collateralBefore * 0.8 * flowPriceDecrease) / debtBefore
		: 0.0
	let collateralValueBefore = collateralBefore * flowPriceDecrease

	log("[Scenario5] After price drop to $\(flowPriceDecrease) (BEFORE rebalance)")
	log("  YT balance:      \(ytBefore) YT")
	log("  FLOW collateral: \(collateralBefore) FLOW")
	log("  Collateral value: $\(collateralValueBefore) MOET")
	log("  MOET debt:       \(debtBefore) MOET")
	log("  Health:          \(healthBeforeRebalance)")

	if healthBeforeRebalance < 1.0 {
		log("  ⚠️  WARNING: Health dropped below 1.0! Position is at liquidation risk!")
		log("  ⚠️  Health = (100 FLOW × 0.8 × $800) / $72,727 = $64,000 / $72,727 = \(healthBeforeRebalance)")
		log("  ⚠️  A 20% price drop causes ~20% health drop from 1.1 → \(healthBeforeRebalance)")
	}

	// Rebalance to restore health to targetHealth (1.3)
	log("[Scenario5] Rebalancing position and yield vault...")
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	let ytAfterFlowDrop = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterFlowDrop = getMOETDebtFromPosition(pid: pid)
	let collateralAfterFlowDrop = getFlowCollateralFromPosition(pid: pid)
	let healthAfterRebalance = debtAfterFlowDrop > 0.0
		? (collateralAfterFlowDrop * 0.8 * flowPriceDecrease) / debtAfterFlowDrop
		: 0.0

	log("[Scenario5] After rebalance (FLOW=$\(flowPriceDecrease), YT=$1.0)")
	log("  YT balance:      \(ytAfterFlowDrop) YT")
	log("  FLOW collateral: \(collateralAfterFlowDrop) FLOW")
	log("  Collateral value: $\(collateralAfterFlowDrop * flowPriceDecrease) MOET")
	log("  MOET debt:       \(debtAfterFlowDrop) MOET")
	log("  Health:          \(healthAfterRebalance)")

	if healthAfterRebalance >= 1.3 {
		log("  ✅ Health restored to targetHealth (1.3)")
	} else if healthAfterRebalance >= 1.1 {
		log("  ✅ Health above minHealth (1.1) but below targetHealth (1.3)")
	} else {
		log("  ❌ Health still below minHealth!")
	}

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
    
    // AutoBalancer sells FUSDEV -> PYUSD0 (reverse on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: true),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Position rebalance borrows MOET -> FUSDEV (forward on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: moetAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(UFix128(yieldPriceIncrease), fee: 100, reverse: false),
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: moetBalanceSlot,
        signer: coaOwnerAccount
    )

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	let ytAfterYTRise = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterYTRise = getMOETDebtFromPosition(pid: pid)
	let collateralAfterYTRise = getFlowCollateralFromPosition(pid: pid)
	let healthAfterYTRise = debtAfterYTRise > 0.0
		? (collateralAfterYTRise * 0.8 * flowPriceDecrease) / debtAfterYTRise
		: 0.0

	log("[Scenario5] After YT rise (FLOW=$\(flowPriceDecrease), YT=$\(yieldPriceIncrease))")
	log("  YT balance:      \(ytAfterYTRise) YT")
	log("  FLOW collateral: \(collateralAfterYTRise) FLOW")
	log("  Collateral value: $\(collateralAfterYTRise * flowPriceDecrease) MOET")
	log("  MOET debt:       \(debtAfterYTRise) MOET")
	log("  Health:          \(healthAfterYTRise)")

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

    // precision comparison of all values
    log("\n=== PRECISION COMPARISON (Before close) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
    log("Actual Yield Tokens:   \(ytBeforeClose)")
    let diff0 = ytBeforeClose > expectedYieldTokenValues[0] ? ytBeforeClose - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - ytBeforeClose
    let sign0 = ytBeforeClose > expectedYieldTokenValues[0] ? "+" : "-"
    log("Difference:            \(sign0)\(diff0)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[0])")
    log("Actual Flow Collateral Value:   \(collateralBeforeClose)")
    let flowDiff0 = collateralBeforeClose > expectedFlowCollateralValues[0] ? collateralBeforeClose - expectedFlowCollateralValues[0] : expectedFlowCollateralValues[0] - collateralBeforeClose
    let flowSign0 = collateralBeforeClose > expectedFlowCollateralValues[0] ? "+" : "-"
    log("Difference:                     \(flowSign0)\(flowDiff0)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[0])")
    log("Actual MOET Debt:   \(debtBeforeClose)")
    let debtDiff0 = debtBeforeClose > expectedDebtValues[0] ? debtBeforeClose - expectedDebtValues[0] : expectedDebtValues[0] - debtBeforeClose
    let debtSign0 = debtBeforeClose > expectedDebtValues[0] ? "+" : "-"
    log("Difference:                     \(debtSign0)\(debtDiff0)")
    log("")

	// Close the yield vault
	// log("\n[Scenario5] Closing yield vault...")

	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
}