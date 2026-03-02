#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

// FlowYieldVaults platform
import "FlowYieldVaults"
// other
import "FlowToken"
import "MOET"
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


access(all)
fun setup() {
    // Deploy all contracts for mainnet fork
    deployContractsForFork()

    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
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
        priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 3000, reverse: false),
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

    // BandOracle is only used for FLOW price for FlowALP collateral
    let symbolPrices: {String: UFix64}   = { 
        "FLOW": 1.0,
        "USD": 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

	let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
	mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

	// Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
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
	log("[TEST] Captured Position ID from event: \(pid)")

	var yieldVaultIDs = getYieldVaultIDs(address: user.address)
	log("[TEST] YieldVault ID: \(yieldVaultIDs![0])")
	Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
	Test.assertEqual(1, yieldVaultIDs!.length)

	var yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

	log("[TEST] Initial yield vault balance: \(yieldVaultBalance ?? 0.0)")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	testSnapshot = getCurrentBlockHeight()

	for flowPrice in flowPrices {
		if (getCurrentBlockHeight() > testSnapshot) {
			Test.reset(to: testSnapshot)
		}
		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) \(yieldVaultBalance ?? 0.0)")

		// === FLOW PRICE CHANGES ===
        setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
            "FLOW": flowPrice,
            "USD": 1.0
        })
        
        // Update WFLOW/PYUSD0 pool to match new Flow price
        // 1 WFLOW = flowPrice PYUSD0
        // Recollat traverses PYUSD0→WFLOW (reverse on this pool)
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: 3000,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(flowPrice), fee: 3000, reverse: true),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: coaOwnerAccount
        )

        // MOET/FUSDEV pool: fee adjustment direction depends on rebalance type
        // Surplus (flowPrice > 1.0): swaps MOET→FUSDEV (forward)
        // Deficit (flowPrice < 1.0): swaps FUSDEV→MOET (reverse)
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: moetAddress,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee: 100, reverse: flowPrice < 1.0),
            tokenABalanceSlot: moetBalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )

		yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])

		log("[TEST] YieldVault balance before flow price \(flowPrice) rebalance: \(yieldVaultBalance ?? 0.0)")

		// Get yield token balance before rebalance
		let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0]) ?? 0.0
		let currentValueBefore = getAutoBalancerCurrentValue(id: yieldVaultIDs![0]) ?? 0.0
		
		rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: false, beFailed: false)
		rebalancePosition(signer: flowALPAccount, pid: pid, force: false, beFailed: false)

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
        
        Test.assert(
            equalAmounts(a: yieldTokensAfter, b: expectedYieldTokens, tolerance: 0.01),
            message: "Expected yield tokens for flow price \(flowPrice) to be \(expectedYieldTokens) but got \(yieldTokensAfter)"
        )

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

	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance after \(flowBalanceAfter)")
}
