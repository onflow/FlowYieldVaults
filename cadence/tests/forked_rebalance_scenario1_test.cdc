#test_fork(network: "testnet", height: nil)

import Test
import BlockchainHelpers

import "test_helpers.cdc"

// standards
import "EVM"
// FlowYieldVaults platform
import "FlowYieldVaults"
// vm bridge
import "FlowEVMBridgeConfig"
// live oracles
import "ERC4626PriceOracles"
// mocks
import "MockOracle"
import "MockSwapper"
// other
import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowCreditMarket"


// check (and update) flow.json for correct addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xd2580caf2ef07c2f)
access(all) let yieldTokenAccount = Test.getAccount(0xd2580caf2ef07c2f)
access(all) let flowCreditMarketAccount = Test.getAccount(0x426f0458ced60037)
access(all) let bandOracleAccount = Test.getAccount(0x9fb6606c300b5051)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	// testnet pool uses BandOracle, so we need to set MockOracle
	// TODO: control live oracles? should be possible with BandOracle but unlikely with ERC4626PriceOracles
	setPoolMockOracle(signer: flowCreditMarketAccount)

    // set mocked token prices
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	let reserveAmount = 100_000_00.0
    // make sure we have enough tokens
	mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
	mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: flowYieldVaultsAccount.address, amount: reserveAmount, beFailed: false)
    // set up liquidity
	setMockSwapperLiquidityConnector(signer: flowYieldVaultsAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: flowYieldVaultsAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: flowYieldVaultsAccount, vaultStoragePath: /storage/flowTokenVault)

	var err = Test.deployContract(
        name: "MockFlowCreditMarketConsumer",
        path: "../../lib/FlowCreditMarket/cadence/contracts/mocks/MockFlowCreditMarketConsumer.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves - this provides MOET liquidity to the pool
	let openRes = executeTransaction(
		"../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		flowCreditMarketAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation, this autobalancer uses mocked oracle
	addStrategyComposer(
		signer: flowYieldVaultsAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
		beFailed: false
	)

	// // Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
	mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_ForkedRebalanceYieldVaultScenario1() {
	let fundingAmount = 1000.0

	let user = Test.createAccount()

	let flowPrices = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0, 3.0, 5.0]
	
	// Expected values from Google sheet calculations
	let expectedYieldTokenValues: {UFix64: UFix64} = {
		0.5: 307.69230769,
		0.8: 492.30769231,
		1.0: 615.38461538,
		1.2: 738.46153846,
		1.5: 923.07692308,
		2.0: 1230.76923077,
		3.0: 1846.15384615,
		5.0: 3076.92307692
	}

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	mintFlow(to: user, amount: fundingAmount)
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

	testSnapshot = getCurrentBlockHeight()

	for flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) \(yieldVaultBalance ?? 0.0)")

		setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrice)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// Get yield token balance before rebalance
		let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let currentValueBefore = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0
		
		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: false, beFailed: false)

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance after flow before \(flowPrice): \(yieldVaultBalance ?? 0.0)")
		
		// Get yield token balance after rebalance
		let yieldTokensAfter = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let currentValueAfter = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0
		
		// Get expected yield tokens from Google sheet calculations
		let expectedYieldTokens = expectedYieldTokenValues[flowPrice] ?? 0.0
		
		log("\n=== SCENARIO 1 DETAILS for Flow Price \(flowPrice) ===")
		log("YieldVault Balance:          \(yieldVaultBalance ?? 0.0)")
		log("Yield Tokens Before:   \(yieldTokensBefore)")
		log("Yield Tokens After:    \(yieldTokensAfter)")
		log("Expected Yield Tokens: \(expectedYieldTokens)")
		let precisionDiff = yieldTokensAfter > expectedYieldTokens ? yieldTokensAfter - expectedYieldTokens : expectedYieldTokens - yieldTokensAfter
		let precisionSign = yieldTokensAfter > expectedYieldTokens ? "+" : "-"
		log("Precision Difference:  \(precisionSign)\(precisionDiff)")
		let percentDiff = expectedYieldTokens > 0.0 ? (precisionDiff / expectedYieldTokens) * 100.0 : 0.0
		log("Percent Difference:    \(precisionSign)\(percentDiff)%")
		let yieldChange = yieldTokensAfter > yieldTokensBefore ? yieldTokensAfter - yieldTokensBefore : yieldTokensBefore - yieldTokensAfter
		let yieldSign = yieldTokensAfter > yieldTokensBefore ? "+" : "-"
		log("Yield Token Change:    \(yieldSign)\(yieldChange)")
		log("Current Value Before:  \(currentValueBefore)")
		log("Current Value After:   \(currentValueAfter)")
		let valueChange = currentValueAfter > currentValueBefore ? currentValueAfter - currentValueBefore : currentValueBefore - currentValueAfter
		let valueSign = currentValueAfter > currentValueBefore ? "+" : "-"
		log("Value Change:          \(valueSign)\(valueChange)")
		log("=============================================\n")
	}

	closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")
}
