import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "MockStrategies"
import "FlowYieldVaults"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@MockStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	deployContracts()

	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	let reserveAmount = 100_000_00.0
	setupMoetVault(protocolAccount, beFailed: false)
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

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

	let openRes = executeTransaction(
		"../../lib/FlowALP/cadence/transactions/flow-alp/position/create_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	addStrategyComposer(
		signer: flowYieldVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@MockStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: MockStrategies.IssuerStoragePath,
		beFailed: false
	)

	mintFlow(to: flowYieldVaultsAccount, amount: 100.0)

	snapshot = getCurrentBlockHeight()
}

access(all)
fun test_DeficitRebalanceWhenYieldPriceDrops() {
	let fundingAmount = 1000.0
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
	log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")

	rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

	let componentCount = getAutoBalancerComponentCount(id: yieldVaultIDs![0])
	log("Component count: \(componentCount)")

	let initialCollateral = getFlowCollateralFromPosition(pid: pid)
	log("Initial collateral: \(initialCollateral)")

	// Drop yield price to 0.90 (below 0.95 threshold)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 0.90)

	let collateralBefore = getFlowCollateralFromPosition(pid: pid)
	log("Collateral before rebalance at price 0.90: \(collateralBefore)")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
	rebalancePosition(signer: protocolAccount, pid: pid, force: false, beFailed: false)

	let collateralAfter = getFlowCollateralFromPosition(pid: pid)
	log("Collateral after rebalance: \(collateralAfter)")
	let collateralChange = collateralAfter > collateralBefore
		? collateralAfter - collateralBefore
		: collateralBefore - collateralAfter
	let changeSign = collateralAfter > collateralBefore ? "+" : "-"
	log("Collateral change: \(changeSign)\(collateralChange)")

	if collateralAfter < collateralBefore {
		log("DEFICIT REBALANCE TRIGGERED - Collateral was withdrawn!")
	} else {
		log("NO DEFICIT REBALANCE - Collateral unchanged")
		if componentCount < 3 {
			log("REASON: rebalanceSource is nil (componentCount = \(componentCount))")
		}
	}

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
}
