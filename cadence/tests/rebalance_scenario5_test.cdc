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
access(all) var collateralTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	deployContracts()

	// set mocked token prices
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: collateralTokenIdentifier, price: 1000.00)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
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
		tokenTypeIdentifier: collateralTokenIdentifier,
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

	snapshot = getCurrentBlockHeight()
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

	let user = Test.createAccount()
	mintFlow(to: user, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

	createYieldVault(
		signer: user,
		strategyIdentifier: strategyIdentifier,
		vaultIdentifier: collateralTokenIdentifier,
		amount: fundingAmount,
		beFailed: false
	)

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	var pid = 1 as UInt64
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
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: collateralTokenIdentifier, price: flowPriceDecrease)

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

	// A 20% FLOW price drop from $1000 → $800 pushes health from targetHealth (1.3) down to ~1.04:
	// below targetHealth (triggering rebalance) but still above 1.0 (not insolvent).
	Test.assert(healthBeforeRebalance < 1.3,
		message: "Expected health to drop below targetHealth (1.3) after 20% FLOW price drop, got \(healthBeforeRebalance)")
	Test.assert(healthBeforeRebalance > 1.0,
		message: "Expected health to remain above 1.0 after 20% FLOW price drop, got \(healthBeforeRebalance)")

	// Rebalance to restore health to targetHealth (1.3)
	log("[Scenario5] Rebalancing position and yield vault...")
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

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

	// The position was undercollateralized (health < targetHealth) after the FLOW price drop,
	// so the topUpSource (AutoBalancer YT → MOET) should have repaid some debt.
	Test.assert(debtAfterFlowDrop < debtBefore,
		message: "Expected MOET debt to decrease after rebalancing undercollateralized position, got \(debtAfterFlowDrop) (was \(debtBefore))")
	Test.assert(ytAfterFlowDrop < ytBefore,
		message: "Expected AutoBalancer YT to decrease after using topUpSource to repay debt, got \(ytAfterFlowDrop) (was \(ytBefore))")
	// Debt repayment only affects the MOET debit — FLOW collateral is untouched.
	Test.assert(collateralAfterFlowDrop == collateralBefore,
		message: "Expected FLOW collateral to be unchanged after debt repayment, got \(collateralAfterFlowDrop) (was \(collateralBefore))")
	// The AutoBalancer has sufficient YT to cover the full repayment needed to reach targetHealth (1.3).
    Test.assert(equalAmounts(a: healthAfterRebalance, b: 1.3, tolerance: 0.00000001),
		message: "Expected health to be fully restored to targetHealth (1.3) after rebalance, got \(healthAfterRebalance)")

	// --- Phase 2: YT price rises from $1.0 to $1.5 ---
	log("[Scenario5] Phase 2: YT price increases to $\(yieldPriceIncrease)")
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPriceIncrease)

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
