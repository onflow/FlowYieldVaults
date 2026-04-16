#test_fork(network: "mainnet-fork", height: 147316310)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "simulation_oct_10_2025_cascade_helpers.cdc"

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

// WBTC on Flow EVM: 717dae2baf7656be9a9b01dee31d571a9d4c9579
access(all) let WBTC_TOKEN_ID = "A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault"
access(all) let WBTC_TYPE = CompositeType(WBTC_TOKEN_ID)!

// 0x01b7e73CDAd95D407e8696E04194a75F19744801

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
// SIMULATION CONSTANTS
// ============================================================================

access(all) let numAgents = 1

access(all) let fundingPerAgent = 1.0

access(all) let initialPrice = btc_oct_2025_prices[0]

// Collateral factor for BTC in the FlowALP pool.
// This determines how much of the collateral value counts toward borrowing capacity.
// effectiveCollateral = collateralValue * collateralFactor
// effectiveHF = effectiveCollateral / debt
// See: lib/FlowALP/cadence/contracts/FlowALPv0.cdc:544-546 (InternalPosition.init defaults)
access(all) let collateralFactor = 0.8

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

    // it removes all the existing scheduled transactions, it is useful to speed up the tests,
    // because otherwise, the existing 41 scheduled transactions will be executed every time we
    // move the time forward, and each taking about 40ms, which make the tests very slow
    // resetting the transaction scheduler will not affect the test results, new scheduled
    // transaction can also be created by the tests.
    resetTransactionScheduler()

    setInfiniteLiquidity()

    // Refresh oracle to avoid stale timestamp (seedPoolWithPYUSD0 triggers oracle check)
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: { "BTC": 100000.0, "USD": 1.0, "PYUSD": 1.0 })

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    seedPoolWithPYUSD0(poolSigner: flowALPAccount, amount: reserveAmount)

    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: reserveAmount)
    transferFlow(signer: whaleFlowAccount, recipient: coaOwnerAccount.address, amount: reserveAmount)
}

// ============================================================================
// HELPERS
// ============================================================================

access(all)
fun setInfiniteLiquidity() {
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
}

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

/// Compute deterministic YT (ERC4626 vault share) price at a given minute.
/// price = 1.0 + yieldAPR * (minute / 365 / 24 / 60)
/// basically negligible yield
access(all) fun ytPriceAtMinute(_ minute: Int): UFix64 {
    return 1.0 + btc_oct_2025_constants.yieldAPR * (UFix64(minute) / 365.0 / 24.0 / 60.0)
}

/// Update all prices for a given simulation minute.
access(all) fun applyPriceTick(btcPrice: UFix64, ytPrice: UFix64, user: Test.TestAccount) {
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": btcPrice,
        "USD": 1.0,
        "PYUSD": 1.0
    })

    let btcPool = btc_oct_2025_pools["pyusd_btc"]!
    let ytPool = btc_oct_2025_pools["moet_fusdev"]!

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

    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: pyusd0Address,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: UFix128(ytPrice),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        tvl: ytPool.size,
        concentration: ytPool.concentration,
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
        signer: user
    )
}

// ============================================================================
// TEST: BTC Oct 10 2025 Cascade -- Minute rebalancing over one day with real prices
// ============================================================================

access(all)
fun test_Btc_Oct_10_2025_Cascade() {
    let prices = btc_oct_2025_prices

    // Create agents
    let users: [Test.TestAccount] = []
    let pids: [UInt64] = []
    let vaultIds: [UInt64] = []

    // Apply initial pricing
    applyPriceTick(btcPrice: initialPrice, ytPrice: ytPriceAtMinute(0), user: coaOwnerAccount)

    var i = 0
    while i < numAgents {
        let user = Test.createAccount()
        transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: 10.0)
        mintBTC(signer: user, amount: fundingPerAgent)
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
            amount: fundingPerAgent,
            beFailed: false
        )

        let pid = (getLastPositionOpenedEvent(Test.eventsOfType(Type<FlowALPv0.Opened>())) as! FlowALPv0.Opened).pid
        let yieldVaultIDs = getYieldVaultIDs(address: user.address)!
        let vaultId = yieldVaultIDs[0]

        let agent = btc_oct_2025_agents[i]

        // forced initial rebalance needs infinite liquidity
        setInfiniteLiquidity()

        // Step 1: Coerce position to the desired initial HF.
        // Set temporary health params with targetHealth=initialHF, then force-rebalance.
        // This makes the on-chain rebalancer push the position to exactly initialHF.
        setPositionHealthParams(
            signer: flowALPAccount,
            pid: pid,
            targetHealth: agent.initialHF,
            minHealth: agent.initialHF - 0.01,
            maxHealth: agent.initialHF + 0.01
        )
        rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

        // Step 2: Set the real health thresholds for the simulation.
        setPositionHealthParams(
            signer: flowALPAccount,
            pid: pid,
            targetHealth: agent.targetHF,
            minHealth: agent.rebalancingHF,
            maxHealth: agent.initialHF
        )

        users.append(user)
        pids.append(pid)
        vaultIds.append(vaultId)

        log("  Agent \(i): pid=\(pid) vaultId=\(vaultId)")
        i = i + 1
    }

    log("\n=== BTC OCT 10 2025 CASCADE SIMULATION ===")
    log("Agents: \(numAgents)")
    log("Funding per agent: \(fundingPerAgent) BTC (~\(fundingPerAgent * initialPrice) PYUSD0)")
    log("Price points: \(prices.length)")
    log("Initial BTC price: $\(prices[0])")
    log("")
    log("Rebalance Triggers:")
    log("  HF (Position): triggers when HF < \(btc_oct_2025_agents[0].rebalancingHF) or HF > \(btc_oct_2025_agents[0].initialHF), rebalances to HF = \(btc_oct_2025_agents[0].targetHF)")
    log("  VR (Vault):    triggers when VR < 0.95 or VR > 1.05, rebalances to VR ~ 1.0")

    var liquidationCount = 0
    var previousBTCPrice = initialPrice
    var lowestPrice = initialPrice
    var highestPrice = initialPrice
    var lowestHF = 100.0
    var prevVaultRebalanceCount = 0
    var prevPositionRebalanceCount = 0

    let startTimestamp = getCurrentBlockTimestamp()

    var minute = 0
    while minute < prices.length {
        let absolutePrice = prices[minute]
        let ytPrice = ytPriceAtMinute(minute)

        if absolutePrice < lowestPrice {
            lowestPrice = absolutePrice
        }
        if absolutePrice > highestPrice {
            highestPrice = absolutePrice
        }

        // Advance blockchain time by 1 minute per step
        let expectedTimestamp = startTimestamp + UFix64(minute) * 60.0
        let currentTimestamp = getCurrentBlockTimestamp()
        if expectedTimestamp > currentTimestamp {
            Test.moveTime(by: Fix64(expectedTimestamp - currentTimestamp))
        }

        // Apply all price updates
        applyPriceTick(btcPrice: absolutePrice, ytPrice: ytPrice, user: users[0])

        // Calculate HF BEFORE rebalancing to see pre-rebalance state
        // effectiveHF = (collateralValue * collateralFactor) / debt
        // This is what determines rebalance triggers (minHealth=1.1, maxHealth=1.5)
        var preRebalanceHFs: [UFix64] = []
        // Calculate vault ratio BEFORE rebalancing (single script call for efficiency)
        // vaultRatio = currentValue / valueOfDeposits
        // Triggers when ratio < 0.95 or ratio > 1.05
        var preVaultRatios: [UFix64] = []
        var a = 0
        while a < numAgents {
            // Calculate HF BEFORE rebalancing
            var preRebalanceHF: UFix64 = UFix64(getPositionHealth(pid: pids[a], beFailed: false))
            preRebalanceHFs.append(preRebalanceHF)
            var preVaultRatio: UFix64 = 1.0
            let preMetrics = getAutoBalancerMetrics(id: vaultIds[a]) ?? [0.0, 0.0]
            if preMetrics[1] > 0.0 {
                preVaultRatio = preMetrics[0] / preMetrics[1]
            }
            preVaultRatios.append(preVaultRatio)

            a = a + 1
        }

        // Potentially rebalance all agents (not forced)
        a = 0
        while a < numAgents {
            rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: false, beFailed: false)
            rebalancePosition(signer: flowALPAccount, pid: pids[a], force: false, beFailed: false)
            a = a + 1
        }

        // Count actual rebalances that occurred
        let currentVaultRebalanceCount = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let currentPositionRebalanceCount = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length

        // Calculate vault ratio AFTER rebalancing (single script call for efficiency)
        var postVaultRatio: UFix64 = 1.0
        let postMetrics = getAutoBalancerMetrics(id: vaultIds[0]) ?? [0.0, 0.0]
        if postMetrics[1] > 0.0 {
            postVaultRatio = postMetrics[0] / postMetrics[1]
        }

        // Calculate HF AFTER rebalancing
        a = 0
        while a < numAgents {
            // Calculate HF AFTER rebalancing
            let postRebalanceHF = UFix64(getPositionHealth(pid: pids[a], beFailed: false))
            let preRebalanceHF = preRebalanceHFs[a]
            let preVaultRatio = preVaultRatios[a]
             // Calculate vault ratio AFTER rebalancing (single script call for efficiency)
            var postVaultRatio: UFix64 = 1.0
            let postMetrics = getAutoBalancerMetrics(id: vaultIds[0]) ?? [0.0, 0.0]
            if postMetrics[1] > 0.0 {
                postVaultRatio = postMetrics[0] / postMetrics[1]
            }
            // Track lowest HF (use pre-rebalance to capture the actual low point)
            if preRebalanceHF < lowestHF && preRebalanceHF > 0.0 {
                lowestHF = preRebalanceHF
            }

            // Log every hour + at price extremes
            // Show both pre and post values to see rebalance effects
            if a == 0 && (minute % 60 == 0 || absolutePrice == lowestPrice || absolutePrice == highestPrice) {
                let vaultRebalancesSinceLastLog = currentVaultRebalanceCount - prevVaultRebalanceCount
                let positionRebalancesSinceLastLog = currentPositionRebalanceCount - prevPositionRebalanceCount
                let hours = minute / 60
                let minutes = minute % 60
                log("  [Time \(hours):\(minutes < 10 ? "0" : "")\(minutes) UTC] price=$\(absolutePrice) yt=\(ytPrice) HF=\(preRebalanceHF)->\(postRebalanceHF) VR=\(preVaultRatio)->\(postVaultRatio) vaultRebalances=\(vaultRebalancesSinceLastLog) positionRebalances=\(positionRebalancesSinceLastLog)")
                prevVaultRebalanceCount = currentVaultRebalanceCount
                prevPositionRebalanceCount = currentPositionRebalanceCount
            }

            // Liquidation occurs when effectiveHF < 1.0 (check pre-rebalance)
            if preRebalanceHF < 1.0 && preRebalanceHF > 0.0 {
                liquidationCount = liquidationCount + 1
                log("  *** LIQUIDATION agent=\(a) on minute \(minute)! HF=\(preRebalanceHF) ***")
            }
            a = a + 1
        }

        previousBTCPrice = absolutePrice
        minute = minute + 1
    }

    // Count actual rebalance events (not just attempts)
    let vaultRebalanceEvents = Test.eventsOfType(Type<DeFiActions.Rebalanced>())
    let positionRebalanceEvents = Test.eventsOfType(Type<FlowALPv0.Rebalanced>())
    let vaultRebalanceCount = vaultRebalanceEvents.length
    let positionRebalanceCount = positionRebalanceEvents.length

    // Final state
    let finalBTCCollateral = getBTCCollateralFromPosition(pid: pids[0])
    let finalDebt = getPYUSD0DebtFromPosition(pid: pids[0])
    let finalYieldTokens = getAutoBalancerBalance(id: vaultIds[0])!
    let finalYtPrice = ytPriceAtMinute(prices.length - 1)
    // Compute effective HF to match contract's rebalancing logic
    let finalEffectiveHF = (finalBTCCollateral * previousBTCPrice * collateralFactor) / finalDebt

    let collateralValuePYUSD0 = finalBTCCollateral * previousBTCPrice
    let ytValuePYUSD0 = finalYieldTokens * finalYtPrice

    let priceUp = previousBTCPrice >= initialPrice
    let priceChangeAbs = priceUp ? (previousBTCPrice - initialPrice) : (initialPrice - previousBTCPrice)
    let priceChangePct = priceChangeAbs / initialPrice
    let priceChangeSign = priceUp ? "+" : "-"

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(numAgents)")
    log("Minutes simulated:   \(prices.length)")
    log("Rebalance attempts:  \(prices.length * numAgents)")
    log("Vault rebalances:    \(vaultRebalanceCount)")
    log("Position rebalances: \(positionRebalanceCount)")
    log("Liquidation count:   \(liquidationCount)")
    log("")
    log("--- Price ---")
    log("Initial BTC price:   $\(initialPrice)")
    log("Lowest BTC price:    $\(lowestPrice)")
    log("Highest BTC price:   $\(highestPrice)")
    log("Final BTC price:     $\(prices[prices.length - 1])")
    log("Price change:        \(priceChangeSign)\(priceChangePct)")
    log("")
    log("--- Position (effective HF with collateralFactor=\(collateralFactor)) ---")
    log("Lowest HF observed:  \(lowestHF)")
    log("Final HF (agent 0):  \(finalEffectiveHF)")
    log("Final collateral:    \(finalBTCCollateral) BTC (value: \(collateralValuePYUSD0) PYUSD0)")
    log("Final debt:          \(finalDebt) PYUSD0")
    log("Final yield tokens:  \(finalYieldTokens) (value: \(ytValuePYUSD0) PYUSD0 @ yt=\(finalYtPrice))")
    log("===========================\n")

    Test.assertEqual(btc_oct_2025_expectedLiquidationCount, liquidationCount)
    Test.assert(finalEffectiveHF > 1.0, message: "Expected final effective HF > 1.0 but got \(finalEffectiveHF)")
    Test.assert(lowestHF > 1.0, message: "Expected lowest effective HF > 1.0 but got \(lowestHF)")

    log("=== TEST PASSED: Zero liquidations on Oct 10 2025 (\(numAgents) agents) ===")
}
