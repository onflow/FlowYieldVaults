import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "MockStrategies"
import "FlowALPv0"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@MockStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

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
	deployContracts()
	snapshot = getCurrentBlockHeight()
}

/// Configure the environment after resetting to the post-deploy snapshot.
/// Each test resets to `snapshot` then calls this with its own starting prices.
access(all)
fun setupEnv(flowPrice: UFix64, yieldPrice: UFix64) {
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrice)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_000.0
	setupMoetVault(protocolAccount, beFailed: false)
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

	// setup FlowALP with a Pool & add FLOW as supported token
	createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
	addSupportedTokenFixedRateInterestCurve(
		signer: protocolAccount,
		tokenTypeIdentifier: flowTokenIdentifier,
		collateralFactor: 0.8,
		borrowFactor: 1.0,
		yearlyRate: UFix128(0.1),
		depositRate: 1_000_000.0,
		depositCapacityCap: 1_000_000.0
	)

	// Set MOET deposit limit fraction to 1.0 (100%) to allow full debt repayment in one transaction
	// Default is 0.05 (5%) which would limit deposits to 50,000 MOET per operation
	setDepositLimitFraction(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, fraction: 1.0)

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves
	let openRes = executeTransaction(
		"../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: flowYieldVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@MockStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: MockStrategies.IssuerStoragePath,
		beFailed: false
	)

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
	mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
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
	mintFlow(to: user, amount: fundingAmount)
	grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	var pid = 1 as UInt64
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)
	log("[Scenario4] YieldVault ID: \(yieldVaultIDs![0]), position ID: \(pid)")

	// --- Phase 1: FLOW price drops from $0.03 to $0.02 ---
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)

	let ytBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtBefore = getMOETDebtFromPosition(pid: pid)
	let collateralBefore = getFlowCollateralFromPosition(pid: pid)

	log("\n[Scenario4] Pre-rebalance state (vault created @ FLOW=$0.03, YT=$1000.0; FLOW oracle now $\(flowPriceDecrease))")
	log("  YT balance:      \(ytBefore) YT")
	log("  FLOW collateral: \(collateralBefore) FLOW (value: \(collateralBefore * flowPriceDecrease) MOET @ $\(flowPriceDecrease)/FLOW)")
	log("  MOET debt:       \(debtBefore) MOET")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

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
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

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
	mintFlow(to: user, amount: fundingAmount)
	grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: flowTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	var pid = 1 as UInt64
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
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPriceDecrease)

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
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

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
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

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
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
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
	log("\n[Scenario5] Closing yield vault...")
	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	// User should receive their collateral back; vault should be destroyed.
	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	Test.assert(flowBalanceAfter > flowBalanceBefore,
		message: "Expected user FLOW balance to increase after closing vault, got \(flowBalanceAfter) (was \(flowBalanceBefore))")

	yieldVaultIDs = getYieldVaultIDs(address: user.address)
	Test.assert(yieldVaultIDs == nil || yieldVaultIDs!.length == 0,
		message: "Expected no yield vaults after close but found \(yieldVaultIDs?.length ?? 0)")
}
