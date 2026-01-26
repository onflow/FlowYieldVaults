#test_fork(network: "mainnet", height: nil)

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
// testnet addresses
// access(all) let flowYieldVaultsAccount = Test.getAccount(0xd2580caf2ef07c2f)
// access(all) let yieldTokenAccount = Test.getAccount(0xd2580caf2ef07c2f)
// access(all) let flowCreditMarketAccount = Test.getAccount(0x426f0458ced60037)
// access(all) let bandOracleAccount = Test.getAccount(0x9fb6606c300b5051)

// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let yieldTokenAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.mUSDCStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
	// testnet/mainnet pool uses BandOracle
    // set all prices to 1.0 for testing
    let symbolPrices: {String: UFix64}   = { 
        "ETH": 1.0, 
        "FLOW": 1.0, 
        "PYUSD": 1.0, 
        "USDC": 1.0,
        "USDT": 1.0,
        "WBTC": 1.0,
        "USDF": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	let reserveAmount = 100_000_00.0
    // service account does not have enough flow to "mint"
	// var mintFlowResult = mintFlow(to: flowCreditMarketAccount, amount: reserveAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)

	mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)
    // TODO: mint evm yield token?

    // on mainnet, we don't use MockFlowCreditMarketConsumer
    // the pool already has MOET liquidity
    // the following code would be necessary for testnet
	// var err = Test.deployContract(
    //     name: "MockFlowCreditMarketConsumer",
    //     path: "../../lib/FlowCreditMarket/cadence/contracts/mocks/MockFlowCreditMarketConsumer.cdc",
    //     arguments: []
    // )
    // Test.expect(err, Test.beNil())

    // // open wrapped position (pushToDrawDownSink)
	// // the equivalent of depositing reserves - this provides MOET liquidity to the pool
	// let openRes = executeTransaction(
	// 	"../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
	// 	[reserveAmount/2.0, /storage/flowTokenVault, true],
	// 	flowCreditMarketAccount
	// )
	// Test.expect(openRes, Test.beSucceeded())

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    // service account does not have enough flow to "mint"
	// mintFlowResult = mintFlow(to: flowYieldVaultsAccount, amount: 100.0)
    // Test.expect(mintFlowResult, Test.beSucceeded())
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)

}

access(all) var testSnapshot: UInt64 = 0

// Token addresses (mainnet) - from flow.json FlowYieldVaultsStrategies deployment
access(all) let yieldTokenAddress = "0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c"  // tauUSDF
access(all) let intermediateToken1 = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"  // MOET
access(all) let univ3PositionManagerAddress = "0xf7F20a346E3097C7d38afDDA65c7C802950195C7"

/// Helper to add liquidity to Pool 1 before running the rebalance test
access(all)
fun addLiquidityToPool1() {
    log("=== Adding Liquidity to Pool 1 ===")
    
    let vmBridgeAccount = Test.getAccount(0x1e4aa0b87d10b141)
    let flowYieldVaultsCOA = getCOA(flowYieldVaultsAccount.address)
    let vmBridgeCOA = getCOA(vmBridgeAccount.address)
    
    // Token addresses (sorted: token0 < token1)
    let token0 = intermediateToken1  // 0x213979...
    let token1 = yieldTokenAddress   // 0xc52E82...
    
    // Transfer Token1 from VM Bridge to FlowYieldVaults
    if vmBridgeCOA != nil && flowYieldVaultsCOA != nil {
        let vmBridgeT1Balance = getERC20Balance(tokenAddressHex: token1, ownerAddressHex: vmBridgeCOA!) ?? 0
        if vmBridgeT1Balance > 0 {
            // Transfer all Token1 to FlowYieldVaults
            transferERC20FromCOA(
                signer: vmBridgeAccount,
                tokenAddressHex: token1,
                recipientAddressHex: flowYieldVaultsCOA!,
                amount: vmBridgeT1Balance,
                beFailed: false
            )
        }
        
        // Get actual balances
        let t0Balance = getERC20Balance(tokenAddressHex: token0, ownerAddressHex: flowYieldVaultsCOA!) ?? 0
        let t1Balance = getERC20Balance(tokenAddressHex: token1, ownerAddressHex: flowYieldVaultsCOA!) ?? 0
        
        log("Token0 balance: \(t0Balance)")
        log("Token1 balance: \(t1Balance)")
        
        if t0Balance > 0 && t1Balance > 0 {
            // Mint liquidity using all available tokens
            addUniV3Liquidity(
                signer: flowYieldVaultsAccount,
                nftManagerAddressHex: univ3PositionManagerAddress,
                token0Hex: token0,
                token1Hex: token1,
                fee: 100,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: t0Balance,
                amount1Desired: t1Balance,
                beFailed: false
            )
            log("Liquidity minted successfully")
        }
    }
    log("=== Liquidity Addition Complete ===")
}

access(all)
fun test_ForkedRebalanceYieldVaultScenario1() {
    // First, add liquidity to Pool 1 to enable swaps
    addLiquidityToPool1()
    
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
    // service account does not have enough flow to "mint"
	// let mintFlowResult =The code snippet `mintFlow(to: user, amount: fundingAmount)` is a function call that mints a specified amount of a token (in this case, Flow tokens) to a specific user account.
    // mintFlow(to: user, amount: fundingAmount)
    // Test.expect(mintFlowResult, Test.beSucceeded())
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

	testSnapshot = getCurrentBlockHeight()

	for flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) \(yieldVaultBalance ?? 0.0)")

		setBandOraclePrice(signer: bandOracleAccount, symbol: "FLOW", price: flowPrice)

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
