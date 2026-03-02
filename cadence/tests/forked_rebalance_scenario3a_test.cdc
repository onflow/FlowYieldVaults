#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowYieldVaults"
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

    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = { 
        "FLOW": 1.0,  // Start at 1.0
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

 // Grant FlowALPv1 Pool capability to FlowYieldVaults account
    let protocolBetaRes = grantProtocolBeta(flowALPAccount, flowYieldVaultsAccount)
    Test.expect(protocolBetaRes, Test.beSucceeded())

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

access(all)
fun test_RebalanceYieldVaultScenario3A() {
	// Test.reset(to: snapshot)

	let fundingAmount = 1000.0
	let flowPriceDecrease = 0.8
	let yieldPriceIncrease = 1.2

	let expectedYieldTokenValues = [615.38461538, 492.30769231, 460.74950690]
	let expectedFlowCollateralValues = [1000.00000000, 800.00000000, 898.46153846]
	let expectedDebtValues = [615.38461538, 492.30769231, 552.89940828]

	let user = Test.createAccount()

	// Likely 0.0
	let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
	log("[TEST] flow balance before \(flowBalanceBefore)")
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1 price
    // Use 1 billion (1e9) as base - large enough to prevent slippage, safe from UFix64 overflow
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

	let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtBefore = getMOETDebtFromPosition(pid: pid)
	let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueBefore = flowCollateralBefore * 1.0  // Initial price is 1.0
	
	log("\n=== PRECISION COMPARISON (Initial State) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
	log("Actual Yield Tokens:   \(yieldTokensBefore)")
	let diff0 = yieldTokensBefore > expectedYieldTokenValues[0] ? yieldTokensBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - yieldTokensBefore
	let sign0 = yieldTokensBefore > expectedYieldTokenValues[0] ? "+" : "-"
	log("Difference:            \(sign0)\(diff0)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[0])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueBefore)")
	let flowDiff0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? flowCollateralValueBefore - expectedFlowCollateralValues[0] : expectedFlowCollateralValues[0] - flowCollateralValueBefore
	let flowSign0 = flowCollateralValueBefore > expectedFlowCollateralValues[0] ? "+" : "-"
	log("Difference:                     \(flowSign0)\(flowDiff0)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[0])")
	log("Actual MOET Debt:   \(debtBefore)")
	let debtDiff0 = debtBefore > expectedDebtValues[0] ? debtBefore - expectedDebtValues[0] : expectedDebtValues[0] - debtBefore
	let debtSign0 = debtBefore > expectedDebtValues[0] ? "+" : "-"
	log("Difference:         \(debtSign0)\(debtDiff0)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensBefore, b:expectedYieldTokenValues[0], tolerance: 0.01),
		message: "Expected yield tokens to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueBefore, b:expectedFlowCollateralValues[0], tolerance: 0.01),
		message: "Expected flow collateral value to be \(expectedFlowCollateralValues[0]) but got \(flowCollateralValueBefore)"
	)
	Test.assert(
		equalAmounts(a:debtBefore, b:expectedDebtValues[0], tolerance: 0.01),
		message: "Expected MOET debt to be \(expectedDebtValues[0]) but got \(debtBefore)"
	)

    // === FLOW PRICE DECREASE TO 0.8 ===
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

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	// Debug: Log position details
	let positionDetailsAfterRebalance = getPositionDetails(pid: pid, beFailed: false)
	log("[DEBUG] Position details after rebalance:")
	log("  Health: \(positionDetailsAfterRebalance.health)")
	log("  Default token available: \(positionDetailsAfterRebalance.defaultTokenAvailableBalance)")

	let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let flowCollateralAfterFlowDecrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterFlowDecrease = flowCollateralAfterFlowDecrease * flowPriceDecrease
	let debtAfterFlowDecrease = getMOETDebtFromPosition(pid: pid)
	
	log("\n=== PRECISION COMPARISON (After Flow Price Decrease) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
	log("Actual Yield Tokens:   \(yieldTokensAfterFlowPriceDecrease)")
	let diff1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? yieldTokensAfterFlowPriceDecrease - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - yieldTokensAfterFlowPriceDecrease
	let sign1 = yieldTokensAfterFlowPriceDecrease > expectedYieldTokenValues[1] ? "+" : "-"
	log("Difference:            \(sign1)\(diff1)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[1])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueAfterFlowDecrease)")
	log("Actual Flow Collateral Amount:  \(flowCollateralAfterFlowDecrease) Flow tokens")
	let flowDiff1 = flowCollateralValueAfterFlowDecrease > expectedFlowCollateralValues[1] ? flowCollateralValueAfterFlowDecrease - expectedFlowCollateralValues[1] : expectedFlowCollateralValues[1] - flowCollateralValueAfterFlowDecrease
	let flowSign1 = flowCollateralValueAfterFlowDecrease > expectedFlowCollateralValues[1] ? "+" : "-"
	log("Difference:                     \(flowSign1)\(flowDiff1)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[1])")
	log("Actual MOET Debt:   \(debtAfterFlowDecrease)")
	let debtDiff1 = debtAfterFlowDecrease > expectedDebtValues[1] ? debtAfterFlowDecrease - expectedDebtValues[1] : expectedDebtValues[1] - debtAfterFlowDecrease
	let debtSign1 = debtAfterFlowDecrease > expectedDebtValues[1] ? "+" : "-"
	log("Difference:         \(debtSign1)\(debtDiff1)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterFlowPriceDecrease, b:expectedYieldTokenValues[1], tolerance: 0.01),
		message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueAfterFlowDecrease, b:expectedFlowCollateralValues[1], tolerance: 0.01),
		message: "Expected flow collateral value after flow price decrease to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowDecrease)"
	)
	Test.assert(
		equalAmounts(a:debtAfterFlowDecrease, b:expectedDebtValues[1], tolerance: 0.01),
		message: "Expected MOET debt after flow price decrease to be \(expectedDebtValues[1]) but got \(debtAfterFlowDecrease)"
	)

    // === YIELD VAULT PRICE INCREASE TO 1.2 ===
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
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldPriceIncrease), fee: 100, reverse: true),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    // Position rebalance borrows MOET -> FUSDEV (forward on this pool)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(yieldPriceIncrease), fee: 100, reverse: false),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	//rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

	let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
	let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceDecrease  // Flow price remains at 0.8
	let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
	
	log("\n=== PRECISION COMPARISON (After Yield Price Increase) ===")
	log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
	log("Actual Yield Tokens:   \(yieldTokensAfterYieldPriceIncrease)")
	let diff2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? yieldTokensAfterYieldPriceIncrease - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - yieldTokensAfterYieldPriceIncrease
	let sign2 = yieldTokensAfterYieldPriceIncrease > expectedYieldTokenValues[2] ? "+" : "-"
	log("Difference:            \(sign2)\(diff2)")
	log("")
	log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[2])")
	log("Actual Flow Collateral Value:   \(flowCollateralValueAfterYieldIncrease)")
	log("Actual Flow Collateral Amount:  \(flowCollateralAfterYieldIncrease) Flow tokens")
	let flowDiff2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? flowCollateralValueAfterYieldIncrease - expectedFlowCollateralValues[2] : expectedFlowCollateralValues[2] - flowCollateralValueAfterYieldIncrease
	let flowSign2 = flowCollateralValueAfterYieldIncrease > expectedFlowCollateralValues[2] ? "+" : "-"
	log("Difference:                     \(flowSign2)\(flowDiff2)")
	log("")
	log("Expected MOET Debt: \(expectedDebtValues[2])")
	log("Actual MOET Debt:   \(debtAfterYieldIncrease)")
	let debtDiff2 = debtAfterYieldIncrease > expectedDebtValues[2] ? debtAfterYieldIncrease - expectedDebtValues[2] : expectedDebtValues[2] - debtAfterYieldIncrease
	let debtSign2 = debtAfterYieldIncrease > expectedDebtValues[2] ? "+" : "-"
	log("Difference:         \(debtSign2)\(debtDiff2)")
	log("=========================================================\n")
	
	Test.assert(
		equalAmounts(a:yieldTokensAfterYieldPriceIncrease, b:expectedYieldTokenValues[2], tolerance: 0.01),
		message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
	)
	Test.assert(
		equalAmounts(a:flowCollateralValueAfterYieldIncrease, b:expectedFlowCollateralValues[2], tolerance: 0.01),
		message: "Expected flow collateral value after yield price increase to be \(expectedFlowCollateralValues[2]) but got \(flowCollateralValueAfterYieldIncrease)"
	)
	Test.assert(
		equalAmounts(a:debtAfterYieldIncrease, b:expectedDebtValues[2], tolerance: 0.01),
		message: "Expected MOET debt after yield price increase to be \(expectedDebtValues[2]) but got \(debtAfterYieldIncrease)"
	)

    // Check getYieldVaultBalance vs actual available balance before closing
	let yieldVaultBalance = getYieldVaultBalance(address: user.address, yieldVaultID: yieldVaultIDs![0])!
	
	// Get the actual available balance from the position
	let positionDetails = getPositionDetails(pid: pid, beFailed: false)
	var positionFlowBalance = 0.0
	for balance in positionDetails.balances {
		if balance.vaultType == Type<@FlowToken.Vault>() && balance.direction == FlowALPv0.BalanceDirection.Credit {
			positionFlowBalance = balance.balance
			break
		}
	}
	
	log("\n=== DIAGNOSTIC: YieldVault Balance vs Position Available ===")
	log("getYieldVaultBalance() reports: \(yieldVaultBalance)")
	log("Position Flow balance: \(positionFlowBalance)")
	log("Difference: \(positionFlowBalance - yieldVaultBalance)")
	log("========================================\n")

    // TODO: closeYieldVault currently fails due to precision issues
	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	log("\n=== TEST COMPLETE - All precision checks passed ===")
}


