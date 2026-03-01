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

	if healthBeforeRebalance < 1.0 {
		log("  ⚠️  WARNING: Health dropped below 1.0! Position is at liquidation risk!")
		log("  ⚠️  Health = (100 FLOW × 0.8 × $800) / $72,727 = $64,000 / $72,727 = \(healthBeforeRebalance)")
		log("  ⚠️  A 20% price drop causes ~20% health drop from 1.1 → \(healthBeforeRebalance)")
	}

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

	if healthAfterRebalance >= 1.3 {
		log("  ✅ Health restored to targetHealth (1.3)")
	} else if healthAfterRebalance >= 1.1 {
		log("  ✅ Health above minHealth (1.1) but below targetHealth (1.3)")
	} else {
		log("  ❌ Health still below minHealth!")
	}

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

	// Debug: Check position 0 state before closing position 1
	log("\n[Scenario5] Checking position 0 state...")
	let pos0Details = getPositionDetails(pid: 0, beFailed: false)
	log("Position 0 balances:")
	for balance in pos0Details.balances {
		let dirStr = balance.direction == FlowALPv0.BalanceDirection.Credit ? "Credit" : "Debit"
		log("  Type: ".concat(balance.vaultType.identifier).concat(", Direction: ").concat(dirStr).concat(", Balance: ").concat(balance.balance.toString()))
	}

	// Close the yield vault
	log("\n[Scenario5] Closing yield vault...")

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
}
