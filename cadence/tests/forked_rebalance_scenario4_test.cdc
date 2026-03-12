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
    // PYUSD = 1.0, FUSDEV = 1000, FLOW = 0.03
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/1000.0, fee: 100, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/0.03, fee: 3000, reverse: false),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/1000.0, fee: 100, reverse: false),
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
        "FLOW": 0.03,  // Start at 0.03
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
fun test_RebalanceYieldVaultScenario4() {
	// Scenario: large FLOW position at real-world low FLOW price
	// FLOW drops further while YT price surges — tests closeYieldVault at extreme price ratios
	let fundingAmount = 1000000.0
	let flowPriceDecrease = 0.02    // FLOW: $0.03 (setup) → $0.02
	let yieldPriceIncrease = 1500.0 // YT:   $1000.0 (setup) → $1500.0

    // expected values derived from original scenario
    let expectedYieldTokenValues = [18.46153846, 12.30769231, 10.72978305]
    let expectedFlowCollateralValues = [1000000.00000000, 1000000.00000000, 1307692.30450000]
    let expectedDebtValues = [18461.53846153, 12307.69231153, 16094.67451692]

	let user = Test.createAccount()
	transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    grantBeta(flowYieldVaultsAccount, user)

    // Set vault to baseline 1:1000 price
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: 1000.0,
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
	log("[Scenario4] YieldVault ID: \(yieldVaultIDs![0]), position ID: \(pid)")

	// --- Phase 1: FLOW price drops from $0.03 to $0.02 ---
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
        priceTokenBPerTokenA: feeAdjustedPrice(1.0/1000.0, fee: 100, reverse: true),
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

	log("\n[Scenario4] Pre-rebalance state (vault created @ FLOW=$0.03, YT=$1000.0; FLOW oracle now $\(flowPriceDecrease))")
	log("  YT balance:      \(ytBefore) YT")
	log("  FLOW collateral: \(collateralBefore) FLOW (value: \(collateralBefore * flowPriceDecrease) MOET @ $\(flowPriceDecrease)/FLOW)")
	log("  MOET debt:       \(debtBefore) MOET")
    // precision comparison of all values
    log("\n=== PRECISION COMPARISON (Before rebalance) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[0])")
    log("Actual Yield Tokens:   \(ytBefore)")
    let diff0 = ytBefore > expectedYieldTokenValues[0] ? ytBefore - expectedYieldTokenValues[0] : expectedYieldTokenValues[0] - ytBefore
    let sign0 = ytBefore > expectedYieldTokenValues[0] ? "+" : "-"
    log("Difference:            \(sign0)\(diff0)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[0])")
    log("Actual Flow Collateral Value:   \(collateralBefore)")
    let flowDiff0 = collateralBefore > expectedFlowCollateralValues[0] ? collateralBefore - expectedFlowCollateralValues[0] : expectedFlowCollateralValues[0] - collateralBefore
    let flowSign0 = collateralBefore > expectedFlowCollateralValues[0] ? "+" : "-"
    log("Difference:                     \(flowSign0)\(flowDiff0)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[0])")
    log("Actual MOET Debt:   \(debtBefore)")
    let debtDiff0 = debtBefore > expectedDebtValues[0] ? debtBefore - expectedDebtValues[0] : expectedDebtValues[0] - debtBefore
    let debtSign0 = debtBefore > expectedDebtValues[0] ? "+" : "-"
    log("Difference:                     \(debtSign0)\(debtDiff0)")
    log("")

	rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
	rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

	let ytAfterFlowDrop = getAutoBalancerBalance(id: yieldVaultIDs![0])!
	let debtAfterFlowDrop = getMOETDebtFromPosition(pid: pid)
	let collateralAfterFlowDrop = getFlowCollateralFromPosition(pid: pid)

	log("\n[Scenario4] After rebalance (FLOW=$\(flowPriceDecrease), YT=$1000.0)")
	log("  YT balance:      \(ytAfterFlowDrop) YT")
	log("  FLOW collateral: \(collateralAfterFlowDrop) FLOW (value: \(collateralAfterFlowDrop * flowPriceDecrease) MOET)")
	log("  MOET debt:       \(debtAfterFlowDrop) MOET")

    // precision comparison of all values
    log("\n=== PRECISION COMPARISON (After rebalance) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[1])")
    log("Actual Yield Tokens:   \(ytAfterFlowDrop)")
    let diff1 = ytAfterFlowDrop > expectedYieldTokenValues[1] ? ytAfterFlowDrop - expectedYieldTokenValues[1] : expectedYieldTokenValues[1] - ytAfterFlowDrop
    let sign1 = ytAfterFlowDrop > expectedYieldTokenValues[1] ? "+" : "-"
    log("Difference:            \(sign1)\(diff1)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[1])")
    log("Actual Flow Collateral Value:   \(collateralAfterFlowDrop)")
    let flowDiff1 = collateralAfterFlowDrop > expectedFlowCollateralValues[1] ? collateralAfterFlowDrop - expectedFlowCollateralValues[1] : expectedFlowCollateralValues[1] - collateralAfterFlowDrop
    let flowSign1 = collateralAfterFlowDrop > expectedFlowCollateralValues[1] ? "+" : "-"
    log("Difference:                     \(flowSign1)\(flowDiff1)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[1])")
    log("Actual MOET Debt:   \(debtAfterFlowDrop)")
    let debtDiff1 = debtAfterFlowDrop > expectedDebtValues[1] ? debtAfterFlowDrop - expectedDebtValues[1] : expectedDebtValues[1] - debtAfterFlowDrop
    let debtSign1 = debtAfterFlowDrop > expectedDebtValues[1] ? "+" : "-"
    log("Difference:                     \(debtSign1)\(debtDiff1)")
    log("")

	// --- Phase 2: YT price rises from $1000.0 to $1500.0 ---
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

	log("\n[Scenario4] After rebalance (FLOW=$\(flowPriceDecrease), YT=$\(yieldPriceIncrease))")
	log("  YT balance:      \(ytAfterYTRise) YT")
	log("  FLOW collateral: \(collateralAfterYTRise) FLOW (value: \(collateralAfterYTRise * flowPriceDecrease) MOET)")
	log("  MOET debt:       \(debtAfterYTRise) MOET")
    
    // precision comparison of all values
    log("\n=== PRECISION COMPARISON (After rebalance) ===")
    log("Expected Yield Tokens: \(expectedYieldTokenValues[2])")
    log("Actual Yield Tokens:   \(ytAfterYTRise)")
    let diff2 = ytAfterYTRise > expectedYieldTokenValues[2] ? ytAfterYTRise - expectedYieldTokenValues[2] : expectedYieldTokenValues[2] - ytAfterYTRise
    let sign2 = ytAfterYTRise > expectedYieldTokenValues[2] ? "+" : "-"
    log("Difference:            \(sign2)\(diff2)")
    log("")
    log("Expected Flow Collateral Value: \(expectedFlowCollateralValues[2])")
    log("Actual Flow Collateral Value:   \(collateralAfterYTRise)")
    let flowDiff2 = collateralAfterYTRise > expectedFlowCollateralValues[2] ? collateralAfterYTRise - expectedFlowCollateralValues[2] : expectedFlowCollateralValues[2] - collateralAfterYTRise
    let flowSign2 = collateralAfterYTRise > expectedFlowCollateralValues[2] ? "+" : "-"
    log("Difference:                     \(flowSign2)\(flowDiff2)")
    log("")
    log("Expected MOET Debt: \(expectedDebtValues[2])")
    log("Actual MOET Debt:   \(debtAfterYTRise)")
    let debtDiff2 = debtAfterYTRise > expectedDebtValues[2] ? debtAfterYTRise - expectedDebtValues[2] : expectedDebtValues[2] - debtAfterYTRise
    let debtSign2 = debtAfterYTRise > expectedDebtValues[2] ? "+" : "-"
    log("Difference:                     \(debtSign2)\(debtDiff2)")
    log("")

	// closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)

	log("\n[Scenario4] Test complete")
}