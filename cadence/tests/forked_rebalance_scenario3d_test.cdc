// Scenario 3D: Flow price decreases 0.5x, Yield vault price increases 1.5x
// This height guarantees enough liquidity for the test
#test_fork(network: "mainnet", height: 142251136)

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
import "EVM"

import "DeFiActions"

// check (and update) flow.json for correct addresses
// mainnet addresses
access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowCreditMarketAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV2.FUSDEVStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

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
access(all) let moetBalanceSlot = 0 as UInt256        // MOET balanceOf at slot 0
access(all) let pyusd0BalanceSlot = 1 as UInt256     // PYUSD0 balanceOf at slot 1
access(all) let fusdevBalanceSlot = 12 as UInt256    // FUSDEV (Morpho VaultV2) balanceOf at slot 12
access(all) let wflowBalanceSlot = 1 as UInt256      // WFLOW balanceOf at slot 1

// Morpho vault storage slots
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256  // slot 15 (packed with lastUpdate and maxRate)
access(all) let morphoVaultTotalSupplySlot = 11 as UInt256  // slot 11

access(all)
fun setup() {
    // Deploy all contracts for mainnet fork
    deployContractsForFork()

    // Upsert strategy config using mainnet addresses
    let upsertRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc"),
            authorizers: [flowYieldVaultsAccount.address],
            signers: [flowYieldVaultsAccount],
            arguments: [
                strategyIdentifier,
                flowTokenIdentifier,
                morphoVaultAddress,
                [morphoVaultAddress, pyusd0Address, wflowAddress],
                [100 as UInt32, 3000 as UInt32]
            ]
        )
    )
    Test.expect(upsertRes, Test.beSucceeded())

    // Add mUSDFStrategyComposer AFTER config is set
    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowYieldVaultsStrategiesV2.MorphoERC4626StrategyComposer>().identifier,
        issuerStoragePath: FlowYieldVaultsStrategiesV2.IssuerStoragePath,
        beFailed: false
    )

    // Setup Uniswap V3 pools with structurally valid state
    // This sets slot0, observations, liquidity, ticks, bitmap, positions, and POOL token balances
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )
    
    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = { 
        "FLOW": 1.0,  // Start at 1.0, will decrease to 0.5 during test
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)
    mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)

    // Follow mainnet setup pattern:
    // 1. Create Pool with MOET as default token (starts with MockOracle)
    createAndStorePool(
        signer: flowCreditMarketAccount,
        defaultTokenIdentifier: Type<@MOET.Vault>().identifier,
        beFailed: false
    )
    
    // 2. Update Pool to use Band Oracle (instead of MockOracle)
    let updateOracleRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("../../lib/FlowALP/cadence/transactions/flow-alp/pool-governance/update_oracle.cdc"),
            authorizers: [flowCreditMarketAccount.address],
            signers: [flowCreditMarketAccount],
            arguments: []
        )
    )
    Test.expect(updateOracleRes, Test.beSucceeded())
    
    // 3. Add FLOW as supported token (matching mainnet setup parameters)
    addSupportedTokenFixedRateInterestCurve(
        signer: flowCreditMarketAccount,
        tokenTypeIdentifier: Type<@FlowToken.Vault>().identifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        yearlyRate: 0.0,  // Simple interest with 0 rate
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Grant FlowALPv0 Pool capability to FlowYieldVaults account
    let protocolBetaRes = grantProtocolBeta(flowCreditMarketAccount, flowYieldVaultsAccount)
    Test.expect(protocolBetaRes, Test.beSucceeded())

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_ForkedRebalanceYieldVaultScenario3D() {
    let fundingAmount = 1000.0
    let flowPriceDecrease = 0.5     // Flow price drops to 0.5x
    let yieldPriceIncrease = 1.5    // Yield vault price increases to 1.5x

    let expectedYieldTokenValues = [615.38461539, 307.69230769, 268.24457594]
    let expectedFlowCollateralValues = [1000.0, 500.0, 653.84615385]
    let expectedDebtValues = [615.38461539, 307.69230769, 402.36686391]

    let user = Test.createAccount()
    
    transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingAmount)
    let betaRes = grantBeta(flowYieldVaultsAccount, user)
    Test.expect(betaRes, Test.beSucceeded())

    // Set vault to baseline 1:1 price
    // Use 1 billion (1e9) as base - large enough to prevent slippage, safe from UFix64 overflow
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        baseAssets: 1000000000.0,  // 1 billion
        priceMultiplier: 1.0,
        signer: user
    )

    log("\n=== Creating Yield Vault ===")
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

    log("\n=== Initial State ===")
    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueBefore = flowCollateralBefore * 1.0
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensBefore) (expected: \(expectedYieldTokenValues[0]))")
    log("Flow Collateral: \(flowCollateralBefore) FLOW")
    log("MOET Debt: \(debtBefore)")
    
    Test.assert(
        equalAmounts(a: yieldTokensBefore, b: expectedYieldTokenValues[0], tolerance: expectedYieldTokenValues[0] * forkedPercentTolerance),
        message: "Expected yield tokens to be \(expectedYieldTokenValues[0]) but got \(yieldTokensBefore)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueBefore, b: expectedFlowCollateralValues[0], tolerance: expectedFlowCollateralValues[0] * forkedPercentTolerance),
        message: "Expected flow collateral value to be \(expectedFlowCollateralValues[0]) but got \(flowCollateralValueBefore)"
    )
    Test.assert(
        equalAmounts(a: debtBefore, b: expectedDebtValues[0], tolerance: expectedDebtValues[0] * forkedPercentTolerance),
        message: "Expected MOET debt to be \(expectedDebtValues[0]) but got \(debtBefore)"
    )

    log("\n=== FLOW PRICE → \(flowPriceDecrease)x ===")
    // Set FLOW price to 0.5 via Band Oracle (for FCM collateral calculation)
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: { 
        "FLOW": flowPriceDecrease,
        "USD": 1.0
    })
    
    // Update pools to reflect new Flow price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: flowPriceDecrease,
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    log("\n=== After Flow Price Decrease ===")
    let yieldTokensAfterFlowPriceDecrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterFlowDecrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterFlowDecrease = flowCollateralAfterFlowDecrease * flowPriceDecrease
    let debtAfterFlowDecrease = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensAfterFlowPriceDecrease) (expected: \(expectedYieldTokenValues[1]))")
    log("Flow Collateral: \(flowCollateralAfterFlowDecrease) FLOW (value: $\(flowCollateralValueAfterFlowDecrease))")
    log("MOET Debt: \(debtAfterFlowDecrease)")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterFlowPriceDecrease, b: expectedYieldTokenValues[1], tolerance: expectedYieldTokenValues[1] * forkedPercentTolerance),
        message: "Expected yield tokens after flow price decrease to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceDecrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueAfterFlowDecrease, b: expectedFlowCollateralValues[1], tolerance: expectedFlowCollateralValues[1] * forkedPercentTolerance),
        message: "Expected flow collateral value after flow price decrease to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowDecrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterFlowDecrease, b: expectedDebtValues[1], tolerance: expectedDebtValues[1] * forkedPercentTolerance),
        message: "Expected MOET debt after flow price decrease to be \(expectedDebtValues[1]) but got \(debtAfterFlowDecrease)"
    )

    log("\n=== YIELD VAULT PRICE → \(yieldPriceIncrease)x ===")
    // Set vault share price to 1.5x by manipulating totalAssets
    // Use 1 billion (1e9) as base - large enough to prevent slippage, safe from UFix64 overflow
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        baseAssets: 1000000000.0,  // 1 billion
        priceMultiplier: yieldPriceIncrease,
        signer: user
    )
    
    // Update FUSDEV pools to reflect 1.5x price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: pyusd0Address,
        fee: 100,
        priceTokenBPerTokenA: yieldPriceIncrease,
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: morphoVaultAddress,
        tokenBAddress: moetAddress,
        fee: 100,
        priceTokenBPerTokenA: yieldPriceIncrease,
        tokenABalanceSlot: fusdevBalanceSlot,
        tokenBBalanceSlot: moetBalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)

    log("\n=== After Yield Vault Price Increase ===")
    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceDecrease
    let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("Yield Tokens: \(yieldTokensAfterYieldPriceIncrease) (expected: \(expectedYieldTokenValues[2]))")
    log("Flow Collateral: \(flowCollateralAfterYieldIncrease) FLOW (value: $\(flowCollateralValueAfterYieldIncrease))")
    log("MOET Debt: \(debtAfterYieldIncrease)")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterYieldPriceIncrease, b: expectedYieldTokenValues[2], tolerance: expectedYieldTokenValues[2] * forkedPercentTolerance),
        message: "Expected yield tokens after yield price increase to be \(expectedYieldTokenValues[2]) but got \(yieldTokensAfterYieldPriceIncrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueAfterYieldIncrease, b: expectedFlowCollateralValues[2], tolerance: expectedFlowCollateralValues[2] * forkedPercentTolerance),
        message: "Expected flow collateral value after yield price increase to be \(expectedFlowCollateralValues[2]) but got \(flowCollateralValueAfterYieldIncrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterYieldIncrease, b: expectedDebtValues[2], tolerance: expectedDebtValues[2] * forkedPercentTolerance),
        message: "Expected MOET debt after yield price increase to be \(expectedDebtValues[2]) but got \(debtAfterYieldIncrease)"
    )

    // Close Yield Vault
    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
}

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
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
            if balance.direction == FlowALPv0.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}
