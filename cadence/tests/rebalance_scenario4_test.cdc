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

access(all)
fun setup() {
	deployContracts()

	// set mocked token prices
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1000.0)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.03)

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
fun test_RebalanceYieldVaultScenario4() {
	// Scenario: large FLOW position at real-world low FLOW price
	// FLOW drops further while YT price surges — tests closeYieldVault at extreme price ratios
	let fundingAmount = 1000000.0
	let flowPriceDecrease = 0.02    // FLOW: $0.03 (setup) → $0.02
	let yieldPriceIncrease = 1500.0 // YT:   $1000.0 (setup) → $1500.0

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
	Test.assert(collateralAfterFlowDrop == collateralBefore,
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
