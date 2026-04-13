#test_fork(network: "mainnet-fork", height: 147316310)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "simulation_flash_crash_moderate_helpers.cdc"

import "FlowYieldVaults"
import "FlowToken"
import "FlowYieldVaultsStrategiesV2"
import "FlowALPv0"
import "DeFiActions"

// ============================================================================
// CADENCE ACCOUNTS
// ============================================================================

access(all) let flowYieldVaultsAccount = Test.getAccount(0xb1d63873c3cc9f79)
access(all) let flowALPAccount = Test.getAccount(0x6b00ff876c299c61)
access(all) let bandOracleAccount = Test.getAccount(0x6801a6222ebf784a)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

// WBTC on Flow EVM
access(all) let WBTC_TOKEN_ID = "A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault"
access(all) let WBTC_TYPE = CompositeType(WBTC_TOKEN_ID)!

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategiesV2.FUSDEVStrategy>().identifier
access(all) var wbtcTokenIdentifier = WBTC_TOKEN_ID

// ============================================================================
// PROTOCOL ADDRESSES
// ============================================================================

access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// ============================================================================
// VAULT & TOKEN ADDRESSES
// ============================================================================

access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let wbtcAddress = "0x717dae2baf7656be9a9b01dee31d571a9d4c9579"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wbtcBalanceSlot = 5 as UInt256

access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

// ============================================================================
// SIMULATION TYPES
// ============================================================================

access(all) struct SimConfig {
    access(all) let prices: [UFix64]
    access(all) let tickIntervalSeconds: UFix64
    access(all) let numAgents: Int
    access(all) let fundingPerAgent: UFix64
    access(all) let yieldAPR: UFix64
    access(all) let expectedLiquidationCount: Int
    /// How often (in ticks) to attempt rebalancing.
    /// 1 = rebalance every tick (default)
    access(all) let rebalanceInterval: Int
    /// Position health thresholds
    access(all) let minHealth: UFix64
    access(all) let targetHealth: UFix64
    access(all) let maxHealth: UFix64
    /// Initial effective HF to coerce the position to at creation (matches Python initial_hf)
    access(all) let initialHF: UFix64
    /// PYUSD0:YT pool TVL in USD
    access(all) let ytPoolTVL: UFix64
    /// PYUSD0:YT pool concentration (0.95 = 95% of liquidity in concentrated range)
    access(all) let ytPoolConcentration: UFix64

    init(
        prices: [UFix64],
        tickIntervalSeconds: UFix64,
        numAgents: Int,
        fundingPerAgent: UFix64,
        yieldAPR: UFix64,
        expectedLiquidationCount: Int,
        rebalanceInterval: Int,
        minHealth: UFix64,
        targetHealth: UFix64,
        maxHealth: UFix64,
        initialHF: UFix64,
        ytPoolTVL: UFix64,
        ytPoolConcentration: UFix64
    ) {
        self.prices = prices
        self.tickIntervalSeconds = tickIntervalSeconds
        self.numAgents = numAgents
        self.fundingPerAgent = fundingPerAgent
        self.yieldAPR = yieldAPR
        self.expectedLiquidationCount = expectedLiquidationCount
        self.rebalanceInterval = rebalanceInterval
        self.minHealth = minHealth
        self.targetHealth = targetHealth
        self.maxHealth = maxHealth
        self.initialHF = initialHF
        self.ytPoolTVL = ytPoolTVL
        self.ytPoolConcentration = ytPoolConcentration
    }
}

access(all) struct SimResult {
    access(all) let rebalanceCount: Int
    access(all) let liquidationCount: Int
    access(all) let lowestHF: UFix64
    access(all) let finalHF: UFix64
    access(all) let lowestPrice: UFix64
    access(all) let finalPrice: UFix64
    access(all) let finalCollateral: UFix64

    init(
        rebalanceCount: Int,
        liquidationCount: Int,
        lowestHF: UFix64,
        finalHF: UFix64,
        lowestPrice: UFix64,
        finalPrice: UFix64,
        finalCollateral: UFix64
    ) {
        self.rebalanceCount = rebalanceCount
        self.liquidationCount = liquidationCount
        self.lowestHF = lowestHF
        self.finalHF = finalHF
        self.lowestPrice = lowestPrice
        self.finalPrice = finalPrice
        self.finalCollateral = finalCollateral
    }
}

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

    // PYUSD0:morphoVault (routing pool)
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

    // PYUSD0:morphoVault (yield token pool) — finite liquidity matching Python sim
    let ytPool = simulation_flash_crash_moderate_pools["moet_yt"]!
    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        tvl: ytPool.size,
        concentration: ytPool.concentration,
        tokenBPriceUSD: 1.0,
        signer: coaOwnerAccount
    )

    // PYUSD0:WBTC (collateral/liquidation pool) — finite liquidity matching Python sim
    let btcPool = simulation_flash_crash_moderate_pools["moet_btc"]!
    let initialBtcPrice = simulation_flash_crash_moderate_prices[0]
    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: wbtcAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: UFix128(initialBtcPrice),
        tokenABalanceSlot: wbtcBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        tvl: btcPool.size,
        concentration: btcPool.concentration,
        tokenBPriceUSD: 1.0,
        signer: coaOwnerAccount
    )

    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": initialBtcPrice,
        "USD": 1.0,
        "PYUSD": 1.0
    })

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    seedPoolWithPYUSD0(poolSigner: flowALPAccount, amount: reserveAmount)

    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: reserveAmount)
    transferFlow(signer: whaleFlowAccount, recipient: coaOwnerAccount.address, amount: reserveAmount)
}

// ============================================================================
// HELPERS
// ============================================================================

access(all) fun getBTCCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == WBTC_TYPE {
            if balance.direction == FlowALPv0.BalanceDirection.Credit {
                return balance.balance
            }
        }
    }
    return 0.0
}

/// Compute deterministic YT (ERC4626 vault share) price at a given tick.
/// price = 1.0 + yieldAPR * (seconds / secondsPerYear)
access(all) fun ytPriceAtTick(_ tick: Int, tickIntervalSeconds: UFix64, yieldAPR: UFix64): UFix64 {
    let secondsPerYear: UFix64 = 31536000.0
    let elapsedSeconds = UFix64(tick) * tickIntervalSeconds
    return 1.0 + yieldAPR * (elapsedSeconds / secondsPerYear)
}

/// Update oracle, collateral pool, and vault share price each tick.
access(all) fun applyPriceTick(btcPrice: UFix64, ytPrice: UFix64, signer: Test.TestAccount) {
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": btcPrice,
        "USD": 1.0,
        "PYUSD": 1.0
    })

    // PYUSD0:WBTC pool — reset to new BTC price with finite liquidity
    let btcPool = simulation_flash_crash_moderate_pools["moet_btc"]!
    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: wbtcAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: UFix128(btcPrice),
        tokenABalanceSlot: wbtcBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        tvl: btcPool.size,
        concentration: btcPool.concentration,
        tokenBPriceUSD: 1.0,
        signer: coaOwnerAccount
    )

    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: ytPrice,
        signer: signer
    )
}

/// Arb bot simulation: reset PYUSD0:FUSDEV pool to peg with finite TVL.
/// Called after all agents trade each tick.
access(all) fun resetYieldPoolToFiniteTVL(ytPrice: UFix64, tvl: UFix64, concentration: UFix64) {
    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: UFix128(ytPrice),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        tvl: tvl,
        concentration: concentration,
        tokenBPriceUSD: 1.0,
        signer: coaOwnerAccount
    )
}

// ============================================================================
// SIMULATION RUNNER
// ============================================================================

access(all) fun runSimulation(config: SimConfig, label: String): SimResult {
    let prices = config.prices
    let initialPrice = prices[0]

    // Clear scheduled transactions inherited from forked mainnet state
    resetTransactionScheduler()

    // Apply initial pricing
    applyPriceTick(btcPrice: initialPrice, ytPrice: ytPriceAtTick(0, tickIntervalSeconds: config.tickIntervalSeconds, yieldAPR: config.yieldAPR), signer: coaOwnerAccount)

    // Create agents
    let users: [Test.TestAccount] = []
    let pids: [UInt64] = []
    let vaultIds: [UInt64] = []

    var i = 0
    while i < config.numAgents {
        let user = Test.createAccount()
        transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: 10.0)
        mintBTC(signer: user, amount: config.fundingPerAgent)
        grantBeta(flowYieldVaultsAccount, user)

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
            vaultIdentifier: wbtcTokenIdentifier,
            amount: config.fundingPerAgent,
            beFailed: false
        )

        let pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid
        let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
        let vaultId = yieldVaultIDs[0]

        // Step 1: Coerce position to the desired initial HF.
        setPositionHealth(
            signer: flowALPAccount,
            pid: pid,
            minHealth: config.initialHF - 0.01,
            targetHealth: config.initialHF,
            maxHealth: config.initialHF + 0.01
        )
        rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

        // Step 2: Set the real health thresholds for the simulation.
        setPositionHealth(
            signer: flowALPAccount,
            pid: pid,
            minHealth: config.minHealth,
            targetHealth: config.targetHealth,
            maxHealth: config.maxHealth
        )

        users.append(user)
        pids.append(pid)
        vaultIds.append(vaultId)

        log("  Agent \(i): pid=\(pid) vaultId=\(vaultId)")
        i = i + 1
    }

    log("\n=== SIMULATION: \(label) ===")
    log("Agents: \(config.numAgents)")
    log("Funding per agent: \(config.fundingPerAgent) BTC (~\(config.fundingPerAgent * initialPrice) PYUSD0)")
    log("Tick interval: \(config.tickIntervalSeconds)s")
    log("Price points: \(prices.length)")
    log("Initial BTC price: $\(prices[0])")
    log("Initial HF: \(config.initialHF)")
    log("")
    log("Rebalance Triggers:")
    log("  HF (Position): triggers when HF < \(config.minHealth), rebalances to HF = \(config.targetHealth)")
    log("  Liquidation:   HF < 1.0 (on-chain effectiveCollateral/effectiveDebt)")
    log("Notes: 20% BTC crash over 5 min, floor for 20 min, exponential recovery")

    var liquidationCount = 0
    var previousBTCPrice = initialPrice
    var lowestPrice = initialPrice
    var highestPrice = initialPrice
    var lowestHF = 100.0
    var prevVaultRebalanceCount = 0
    var prevPositionRebalanceCount = 0

    let startTimestamp = getCurrentBlockTimestamp()

    var step = 0
    while step < prices.length {
        let absolutePrice = prices[step]
        let ytPrice = ytPriceAtTick(step, tickIntervalSeconds: config.tickIntervalSeconds, yieldAPR: config.yieldAPR)

        if absolutePrice < lowestPrice {
            lowestPrice = absolutePrice
        }
        if absolutePrice > highestPrice {
            highestPrice = absolutePrice
        }

        if absolutePrice == previousBTCPrice {
            step = step + 1
            continue
        }

        let expectedTimestamp = startTimestamp + UFix64(step) * config.tickIntervalSeconds
        let currentTimestamp = getCurrentBlockTimestamp()
        if expectedTimestamp > currentTimestamp {
            Test.moveTime(by: Fix64(expectedTimestamp - currentTimestamp))
        }

        applyPriceTick(btcPrice: absolutePrice, ytPrice: ytPrice, signer: users[0])

        // Check HF for ALL agents BEFORE rebalancing
        var a = 0
        while a < config.numAgents {
            let hf = UFix64(getPositionHealth(pid: pids[a], beFailed: false))
            if hf < lowestHF && hf > 0.0 {
                lowestHF = hf
            }
            if hf < 1.0 && hf > 0.0 {
                liquidationCount = liquidationCount + 1
                log("  *** LIQUIDATION agent=\(a) at t=\(step)! HF=\(hf) ***")
            }
            a = a + 1
        }
        let preRebalanceHF = UFix64(getPositionHealth(pid: pids[0], beFailed: false))

        // Rebalance agents sequentially — each swap moves pool price for next agent
        if config.rebalanceInterval <= 1 || step % config.rebalanceInterval == 0 {
            a = 0
            while a < config.numAgents {
                rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: false, beFailed: false)
                rebalancePosition(signer: flowALPAccount, pid: pids[a], force: false, beFailed: false)
                a = a + 1
            }

            // Arb bot: reset PYUSD0:FUSDEV pool to peg with finite TVL
            resetYieldPoolToFiniteTVL(ytPrice: ytPrice, tvl: config.ytPoolTVL, concentration: config.ytPoolConcentration)
        }

        // Count actual rebalances that occurred this tick
        let currentVaultRebalanceCount = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let currentPositionRebalanceCount = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length
        let tickVaultRebalances = currentVaultRebalanceCount - prevVaultRebalanceCount
        let tickPositionRebalances = currentPositionRebalanceCount - prevPositionRebalanceCount
        prevVaultRebalanceCount = currentVaultRebalanceCount
        prevPositionRebalanceCount = currentPositionRebalanceCount

        let postRebalanceHF = UFix64(getPositionHealth(pid: pids[0], beFailed: false))

        // Log every tick with agent 0 pre->post HF
        log("  [t=\(step)] price=$\(absolutePrice) yt=\(ytPrice) HF=\(preRebalanceHF)->\(postRebalanceHF) vaultRebalances=\(tickVaultRebalances) positionRebalances=\(tickPositionRebalances)")

        previousBTCPrice = absolutePrice

        step = step + 1
    }

    // Count actual rebalance events (not just attempts)
    let vaultRebalanceCount = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
    let positionRebalanceCount = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length

    // Final state
    let finalHF = UFix64(getPositionHealth(pid: pids[0], beFailed: false))
    let finalBTCCollateral = getBTCCollateralFromPosition(pid: pids[0])
    let finalDebt = getPYUSD0DebtFromPosition(pid: pids[0])
    let finalYieldTokens = getAutoBalancerBalance(id: vaultIds[0])!
    let finalYtPrice = ytPriceAtTick(prices.length - 1, tickIntervalSeconds: config.tickIntervalSeconds, yieldAPR: config.yieldAPR)
    let finalPrice = prices[prices.length - 1]
    let collateralValuePYUSD0 = finalBTCCollateral * previousBTCPrice
    let ytValuePYUSD0 = finalYieldTokens * finalYtPrice

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(config.numAgents)")
    log("Rebalance attempts:  \(prices.length * config.numAgents)")
    log("Vault rebalances:    \(vaultRebalanceCount)")
    log("Position rebalances: \(positionRebalanceCount)")
    log("Liquidation count:   \(liquidationCount)")
    log("")
    log("--- Price ---")
    log("Initial BTC price:   $\(initialPrice)")
    log("Lowest BTC price:    $\(lowestPrice)")
    log("Highest BTC price:   $\(highestPrice)")
    log("Final BTC price:     $\(finalPrice)")
    log("")
    log("--- Position ---")
    log("Initial HF:          \(config.initialHF)")
    log("Lowest HF observed:  \(lowestHF)")
    log("Final HF (agent 0):  \(finalHF)")
    log("Final collateral:    \(finalBTCCollateral) BTC (value: \(collateralValuePYUSD0) PYUSD0)")
    log("Final debt:          \(finalDebt) PYUSD0")
    log("Final yield tokens:  \(finalYieldTokens) (value: \(ytValuePYUSD0) PYUSD0 @ yt=\(finalYtPrice))")
    log("===========================\n")

    return SimResult(
        rebalanceCount: positionRebalanceCount,
        liquidationCount: liquidationCount,
        lowestHF: lowestHF,
        finalHF: finalHF,
        lowestPrice: lowestPrice,
        finalPrice: finalPrice,
        finalCollateral: finalBTCCollateral
    )
}

// ============================================================================
// TEST
// ============================================================================

access(all)
fun test_FlashCrashModerate_ZeroLiquidations() {
    let result = runSimulation(
        config: SimConfig(
            prices: simulation_flash_crash_moderate_prices,
            tickIntervalSeconds: 60.0, // 1 min per tick, matching Python sim
            numAgents: 10,
            fundingPerAgent: 1.0,
            yieldAPR: simulation_flash_crash_moderate_constants.yieldAPR,
            expectedLiquidationCount: 0,
            rebalanceInterval: 5, // every 5 ticks
            minHealth: 1.05,
            targetHealth: 1.08,
            maxHealth: UFix64.max, // Python sim has no upper health bound
            initialHF: 1.15,
            ytPoolTVL: simulation_flash_crash_moderate_pools["moet_yt"]!.size,
            ytPoolConcentration: simulation_flash_crash_moderate_pools["moet_yt"]!.concentration
        ),
        label: "FlashCrashModerate"
    )

    Test.assertEqual(0, result.liquidationCount)
    Test.assert(result.finalHF > 1.0, message: "Expected final HF > 1.0 but got \(result.finalHF)")
    Test.assert(result.lowestHF > 1.0, message: "Expected lowest HF > 1.0 but got \(result.lowestHF)")
    // No liquidations means collateral should never decrease from initial funding
    Test.assert(result.finalCollateral >= 1.0, message: "Expected collateral >= 1.0 BTC but got \(result.finalCollateral)")

    log("=== TEST PASSED: Zero liquidations under flash crash ===")
}
