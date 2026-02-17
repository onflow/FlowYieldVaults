// Scenario 3C: Flow price increases 2x, Yield vault price increases 2x
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
import "FlowALPv1"
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

// MOET - Flow Omni Token
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
access(all) let morphoVaultTotalAssetsSlot = "0x000000000000000000000000000000000000000000000000000000000000000f"  // slot 15 (packed with lastUpdate and maxRate)

access(all)
fun setup() {
    Test.commitBlock()

    // Deploy mock EVM contract to enable vm.store/vm.load cheatcodes
    var err = Test.deployContract(name: "EVM", path: "../contracts/mocks/EVM.cdc", arguments: [])
    Test.expect(err, Test.beNil())

    // Deploy dependencies not present on mainnet yet/outdated
    err = Test.deployContract(name: "DeFiActions", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "DeFiActionsUtils", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "FungibleTokenConnectors", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "SwapConnectors", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/SwapConnectors.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "FlowALPMath", path: "../../lib/FlowCreditMarket/cadence/lib/FlowALPMath.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    
    // Deploy DeFiActions dependencies
    err = Test.deployContract(name: "DeFiActions", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc", arguments: [])
    if err != nil {
        log("DeFiActions deployment error: ".concat(err!.message))
    }
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "DeFiActionsUtils", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc", arguments: [])
    if err != nil {
        log("DeFiActionsUtils deployment error: ".concat(err!.message))
    }
    Test.expect(err, Test.beNil())
    
    // Skip MockOracle and MockDexSwapper deployment - they have unresolved address conflicts
    
    // Deploy FlowALPv1
    err = Test.deployContract(name: "FlowALPv1", path: "../../lib/FlowCreditMarket/cadence/contracts/FlowALPv1.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(name: "EVMAmountUtils", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/evm/EVMAmountUtils.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "MorphoERC4626SinkConnectors", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SinkConnectors.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "MorphoERC4626SwapConnectors", path: "../../lib/FlowCreditMarket/FlowActions/cadence/contracts/connectors/evm/morpho/MorphoERC4626SwapConnectors.cdc", arguments: [])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "FlowYieldVaultsStrategiesV2", path: "../contracts/FlowYieldVaultsStrategiesV2.cdc", arguments: [
        "0xca6d7Bb03334bBf135902e1d919a5feccb461632",
        "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341",
        "0x370A8DF17742867a44e56223EC20D82092242C85"
    ])
    Test.expect(err, Test.beNil())
    err = Test.deployContract(name: "FlowYieldVaults", path: "../contracts/FlowYieldVaults.cdc", arguments: [])
    Test.expect(err, Test.beNil())

    // Upsert strategy config (temporary - this project has been completely mangled, it's borderline untestable and we have had to
    // go through a lot to try to make it work)
    let upsertRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("../transactions/flow-yield-vaults/admin/upsert_strategy_config.cdc"),
            authorizers: [flowYieldVaultsAccount.address],
            signers: [flowYieldVaultsAccount],
            arguments: [
                strategyIdentifier,
                flowTokenIdentifier,
                "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D",
                ["0xd069d989e2F44B70c65347d1853C0c67e10a9F8D", "0x99aF3EeA856556646C98c8B9b2548Fe815240750", "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"],
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
    setupUniswapPools(signer: coaOwnerAccount)

    // BandOracle is used for FLOW and USD (MOET) prices
    let symbolPrices = { 
        "FLOW": 1.0,  // Start at 1.0, will increase to 2.0 during test
        "USD": 1.0    // MOET is pegged to USD, always 1.0
    }
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: symbolPrices)

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowCreditMarketAccount.address, amount: reserveAmount)
    mintMoet(signer: flowCreditMarketAccount, to: flowCreditMarketAccount.address, amount: reserveAmount, beFailed: false)

    // SKIP Pool creation for now - it requires mocks which have deployment issues
    // The test will likely fail when trying to use the Pool, but let's see what error we get
    log("WARNING: Skipping Pool creation - test may fail when trying to open credit position")

    // Grant FlowALPv1 Pool capability to FlowYieldVaults account (this will probably fail)
    // let protocolBetaRes = grantProtocolBeta(flowCreditMarketAccount, flowYieldVaultsAccount)
    // Test.expect(protocolBetaRes, Test.beSucceeded())

    // Fund FlowYieldVaults account for scheduling fees
    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: 100.0)
}

access(all) var testSnapshot: UInt64 = 0
access(all)
fun test_ForkedRebalanceYieldVaultScenario3C() {
    let fundingAmount = 1000.0
    let flowPriceIncrease = 2.0
    let yieldPriceIncrease = 2.0

    // Expected values from Google sheet calculations
    let expectedYieldTokenValues = [615.38461539, 1230.76923077, 994.08284024]
    let expectedFlowCollateralValues = [1000.0, 2000.0, 3230.76923077]
    let expectedDebtValues = [615.38461539, 1230.76923077, 1988.16568047]

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
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        baseAssets: 1000000000.0,  // 1 billion
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
    var pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv1.Opened>())) as! FlowALPv1.Opened).pid

    var yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil but encountered nil")
    Test.assertEqual(1, yieldVaultIDs!.length)

    let yieldTokensBefore = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    let flowCollateralBefore = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueBefore = flowCollateralBefore * 1.0
    
    log("\n=== Initial State ===")
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

    // === FLOW PRICE INCREASE TO 2.0 ===
    log("\n=== FLOW PRICE → 2.0x ===")
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPriceIncrease,
        "USD": 1.0
    })

    // Update PYUSD0/FLOW pool to match new Flow price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: wflowAddress,
        fee: 3000,
        priceTokenBPerTokenA: 2.0,  // Flow is 2x the price of PYUSD0
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: wflowBalanceSlot,
        signer: coaOwnerAccount
    )

    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterFlowPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterFlowIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterFlowIncrease = flowCollateralAfterFlowIncrease * flowPriceIncrease
    let debtAfterFlowIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== After Flow Price Increase ===")
    log("Yield Tokens: \(yieldTokensAfterFlowPriceIncrease) (expected: \(expectedYieldTokenValues[1]))")
    log("Flow Collateral: \(flowCollateralAfterFlowIncrease) FLOW (value: $\(flowCollateralValueAfterFlowIncrease))")
    log("MOET Debt: \(debtAfterFlowIncrease)")
    
    Test.assert(
        equalAmounts(a: yieldTokensAfterFlowPriceIncrease, b: expectedYieldTokenValues[1], tolerance: expectedYieldTokenValues[1] * forkedPercentTolerance),
        message: "Expected yield tokens after flow price increase to be \(expectedYieldTokenValues[1]) but got \(yieldTokensAfterFlowPriceIncrease)"
    )
    Test.assert(
        equalAmounts(a: flowCollateralValueAfterFlowIncrease, b: expectedFlowCollateralValues[1], tolerance: expectedFlowCollateralValues[1] * forkedPercentTolerance),
        message: "Expected flow collateral value after flow price increase to be \(expectedFlowCollateralValues[1]) but got \(flowCollateralValueAfterFlowIncrease)"
    )
    Test.assert(
        equalAmounts(a: debtAfterFlowIncrease, b: expectedDebtValues[1], tolerance: expectedDebtValues[1] * forkedPercentTolerance),
        message: "Expected MOET debt after flow price increase to be \(expectedDebtValues[1]) but got \(debtAfterFlowIncrease)"
    )

    // === YIELD VAULT PRICE INCREASE TO 2.0 ===
    log("\n=== YIELD VAULT PRICE → 2.0x ===")
    
    // Use 1 billion (1e9) as base - large enough to prevent slippage, safe from UFix64 overflow
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: UInt256(1),
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        baseAssets: 1000000000.0,  // 1 billion
        priceMultiplier: yieldPriceIncrease,
        signer: user
    )
    
    // Update FUSDEV pools to 2:1 price
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 2.0,
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
    
    // Trigger the buggy rebalance
    rebalanceYieldVault(signer: flowYieldVaultsAccount, id: yieldVaultIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: flowCreditMarketAccount, pid: pid, force: true, beFailed: false)

    let yieldTokensAfterYieldPriceIncrease = getAutoBalancerBalance(id: yieldVaultIDs![0])!
    let flowCollateralAfterYieldIncrease = getFlowCollateralFromPosition(pid: pid)
    let flowCollateralValueAfterYieldIncrease = flowCollateralAfterYieldIncrease * flowPriceIncrease
    let debtAfterYieldIncrease = getMOETDebtFromPosition(pid: pid)
    
    log("\n=== After Yield Vault Price Increase ===")
    log("Yield Tokens: \(yieldTokensAfterYieldPriceIncrease) (expected: \(expectedYieldTokenValues[2]))")
    log("Flow Collateral: \(flowCollateralAfterYieldIncrease) FLOW (value: $\(flowCollateralValueAfterYieldIncrease))")
    log("MOET Debt: \(debtAfterYieldIncrease)")
    log("BUG: Should have WITHDRAWN to \(expectedYieldTokenValues[2]), but DEPOSITED instead!")
    
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

    closeYieldVault(signer: user, id: yieldVaultIDs![0], beFailed: false)
    
    log("\n=== TEST COMPLETE ===")
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

// Setup Uniswap V3 pools with valid state at specified prices
access(all) fun setupUniswapPools(signer: Test.TestAccount) {
    log("\n=== Setting up Uniswap V3 pools ===")
    
    let fusdevDexPremium = 1.01
    
    let poolConfigs: [{String: AnyStruct}] = [
        {
            "name": "PYUSD0/FUSDEV",
            "tokenA": pyusd0Address,
            "tokenB": morphoVaultAddress,
            "fee": 100 as UInt64,
            "tokenABalanceSlot": pyusd0BalanceSlot,
            "tokenBBalanceSlot": fusdevBalanceSlot,
            "priceTokenBPerTokenA": fusdevDexPremium
        },
        {
            "name": "PYUSD0/FLOW",
            "tokenA": pyusd0Address,
            "tokenB": wflowAddress,
            "fee": 3000 as UInt64,
            "tokenABalanceSlot": pyusd0BalanceSlot,
            "tokenBBalanceSlot": wflowBalanceSlot,
            "priceTokenBPerTokenA": 1.0
        },
        {
            "name": "MOET/FUSDEV",
            "tokenA": moetAddress,
            "tokenB": morphoVaultAddress,
            "fee": 100 as UInt64,
            "tokenABalanceSlot": moetBalanceSlot,
            "tokenBBalanceSlot": fusdevBalanceSlot,
            "priceTokenBPerTokenA": fusdevDexPremium
        }
    ]
    
    for config in poolConfigs {
        let name = config["name"]! as! String
        log("Setting up ".concat(name))
        
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: config["tokenA"]! as! String,
            tokenBAddress: config["tokenB"]! as! String,
            fee: config["fee"]! as! UInt64,
            priceTokenBPerTokenA: config["priceTokenBPerTokenA"]! as! UFix64,
            tokenABalanceSlot: config["tokenABalanceSlot"]! as! UInt256,
            tokenBBalanceSlot: config["tokenBBalanceSlot"]! as! UInt256,
            signer: signer
        )
    }
    
    log("✓ All pools seeded")
}

// Helper function to get Flow collateral from position
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            if balance.direction == FlowALPv1.BalanceDirection.Credit {
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
            if balance.direction == FlowALPv1.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}

