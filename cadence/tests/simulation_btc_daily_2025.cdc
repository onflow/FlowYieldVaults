#test_fork(network: "mainnet-fork", height: 147316310)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "btc_daily_2025_helpers.cdc"

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
// SIMULATION CONFIG
// ============================================================================

access(all) let numAgents = 1

access(all) let fundingPerAgent = 1.0

access(all) let initialPrice = btc_daily_2025_prices[0]

access(all) let yieldAPR = btc_daily_2025_constants.yieldAPR
access(all) let daysPerYear = 365.0
access(all) let secondsPerDay = 86400.0

// Collateral factor for BTC in the FlowALP pool.
// This determines how much of the collateral value counts toward borrowing capacity.
// effectiveCollateral = collateralValue * collateralFactor
// effectiveHF = effectiveCollateral / debt
//
// Position rebalance thresholds (in effective HF terms):
//   - minHealth = 1.1: triggers top-up from source when effectiveHF < 1.1
//   - targetHealth = 1.3: rebalance aims to restore effectiveHF to 1.3
//   - maxHealth = 1.5: triggers push to sink when effectiveHF > 1.5
// See: lib/FlowALP/cadence/contracts/FlowALPv0.cdc:544-546 (InternalPosition.init defaults)
access(all) let collateralFactor = 0.8

// Vault (AutoBalancer) rebalance thresholds.
// The vault tracks yield token value relative to historical deposits.
// vaultRatio = currentValue / valueOfDeposits
//
// Vault rebalance triggers when:
//   - vaultRatio < 0.95 (lowerThreshold): pulls from source to buy more yield tokens
//   - vaultRatio > 1.05 (upperThreshold): pushes to sink to sell yield tokens
// See: lib/FlowALP/FlowActions/cadence/contracts/interfaces/DeFiActions.cdc:763-764
// See: cadence/contracts/FlowYieldVaultsStrategiesV2.cdc:706-707 (FUSDEVStrategy defaults)
access(all) let vaultLowerThreshold = 0.95
access(all) let vaultUpperThreshold = 1.05

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

    // it removes all the existing scheduled transactions, it is useful to speed up the tests,
    // because otherwise, the existing 41 scheduled transactions will be executed every time we
    // move the time forward, and each taking about 40ms, which make the tests very slow
    // after 365 days of simulation, the total delay would be 10mins.
    // resetting the transaction scheduler will not affect the test results, new scheduled
    // transaction can also be created by the tests.
    resetTransactionScheduler()

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

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: { "BTC": 60000.0, "USD": 1.0, "PYUSD": 1.0 })
    seedPoolWithPYUSD0(poolSigner: flowALPAccount, amount: 70_000.0)

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

/// Compute deterministic YT (ERC4626 vault share) price at a given day.
/// price = 1.0 + yieldAPR * (day / 365)
access(all) fun ytPriceAtDay(_ day: Int): UFix64 {
    return 1.0 + yieldAPR * (UFix64(day) / daysPerYear)
}

/// Update all prices for a given simulation day.
access(all) fun applyPriceTick(btcPrice: UFix64, ytPrice: UFix64, user: Test.TestAccount) {
    // Refresh ALL oracle symbols each tick — not just BTC. The mainnet BandOracleConnectors
    // has a 1-hour staleThreshold, and the sim advances 1 day per tick. Any symbol not
    // refreshed here will go stale and cause positionHealth() to revert.
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": btcPrice,
        "USD": 1.0,
        "PYUSD": 1.0,
        "FLOW": 1.0
    })

    let btcPool = btc_daily_2025_pools["pyusd_btc"]!
    let ytPool = btc_daily_2025_pools["pyusd0_fusdev"]!

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
        tokenBPriceUSD: ytPrice,
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
// TEST: BTC Daily 2025 -- Daily Rebalancing with Real Prices
// ============================================================================

access(all)
fun test_BtcDaily2025_DailyRebalancing() {
    let prices = btc_daily_2025_prices
    let dates = btc_daily_2025_dates

    // Create agents
    let users: [Test.TestAccount] = []
    let pids: [UInt64] = []
    let vaultIds: [UInt64] = []

    // Apply initial pricing
    applyPriceTick(btcPrice: initialPrice, ytPrice: ytPriceAtDay(0), user: coaOwnerAccount)

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

        users.append(user)
        pids.append(pid)
        vaultIds.append(vaultId)

        log("  Agent \(i): pid=\(pid) vaultId=\(vaultId)")
        i = i + 1
    }

    log("\n=== BTC DAILY 2025 SIMULATION ===")
    log("Agents: \(numAgents)")
    log("Funding per agent: \(fundingPerAgent) BTC (~\(fundingPerAgent * initialPrice) PYUSD0)")
    log("Duration: \(btc_daily_2025_durationDays) days")
    log("Price points: \(prices.length)")
    log("Initial BTC price: $\(prices[0])")
    log("Notes: \(btc_daily_2025_notes)")
    log("")
    log("Rebalance Triggers:")
    log("  HF (Position): triggers when HF < 1.1 or HF > 1.5, rebalances to HF = 1.3")
    log("  VR (Vault):    triggers when VR < 0.95 or VR > 1.05, rebalances to VR ~ 1.0")

    var liquidationCount = 0
    var previousBTCPrice = initialPrice
    var lowestPrice = initialPrice
    var highestPrice = initialPrice
    var lowestHF = 100.0
    var prevVaultRebalanceCount = 0
    var prevPositionRebalanceCount = 0

    let startTimestamp = getCurrentBlockTimestamp()

    var day = 0
    while day < prices.length {
        let absolutePrice = prices[day]
        let ytPrice = ytPriceAtDay(day)

        if absolutePrice < lowestPrice {
            lowestPrice = absolutePrice
        }
        if absolutePrice > highestPrice {
            highestPrice = absolutePrice
        }

        // Advance blockchain time by 1 day per step
        let expectedTimestamp = startTimestamp + UFix64(day) * secondsPerDay
        let currentTimestamp = getCurrentBlockTimestamp()
        if expectedTimestamp > currentTimestamp {
            Test.moveTime(by: Fix64(expectedTimestamp - currentTimestamp))
        }

        // Apply all price updates
        applyPriceTick(btcPrice: absolutePrice, ytPrice: ytPrice, user: users[0])

        // Calculate HF BEFORE rebalancing to see pre-rebalance state
        // effectiveHF = (collateralValue * collateralFactor) / debt
        // This is what determines rebalance triggers (minHealth=1.1, maxHealth=1.5)
        var preRebalanceHF: UFix64 = 0.0
        var a = 0
        while a < numAgents {
            if a == 0 {
                let btcCollateral = getBTCCollateralFromPosition(pid: pids[a])
                let btcCollateralValue = btcCollateral * absolutePrice
                let effectiveCollateral = btcCollateralValue * collateralFactor
                let debt = getPYUSD0DebtFromPosition(pid: pids[a])
                if debt > 0.0 {
                    preRebalanceHF = effectiveCollateral / debt
                }
            }
            a = a + 1
        }

        // Calculate vault ratio BEFORE rebalancing (single script call for efficiency)
        // vaultRatio = currentValue / valueOfDeposits
        // Triggers when ratio < 0.95 or ratio > 1.05
        var preVaultRatio: UFix64 = 1.0
        let preMetrics = getAutoBalancerMetrics(id: vaultIds[0]) ?? [0.0, 0.0]
        if preMetrics[1] > 0.0 {
            preVaultRatio = preMetrics[0] / preMetrics[1]
        }

        // Potentially rebalance all agents (not forced)
        a = 0
        while a < numAgents {
            rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: false, beFailed: false)
            rebalancePosition(signer: flowALPAccount, pid: pids[a], force: false, beFailed: false)
            a = a + 1
        }

        // Count actual rebalances that occurred this day
        let currentVaultRebalanceCount = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
        let currentPositionRebalanceCount = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length
        let dayVaultRebalances = currentVaultRebalanceCount - prevVaultRebalanceCount
        let dayPositionRebalances = currentPositionRebalanceCount - prevPositionRebalanceCount
        prevVaultRebalanceCount = currentVaultRebalanceCount
        prevPositionRebalanceCount = currentPositionRebalanceCount

        // Calculate vault ratio AFTER rebalancing (single script call for efficiency)
        var postVaultRatio: UFix64 = 1.0
        let postMetrics = getAutoBalancerMetrics(id: vaultIds[0]) ?? [0.0, 0.0]
        if postMetrics[1] > 0.0 {
            postVaultRatio = postMetrics[0] / postMetrics[1]
        }

        // Calculate HF AFTER rebalancing
        a = 0
        while a < numAgents {
            let btcCollateral = getBTCCollateralFromPosition(pid: pids[a])
            let btcCollateralValue = btcCollateral * absolutePrice
            let effectiveCollateral = btcCollateralValue * collateralFactor
            let debt = getPYUSD0DebtFromPosition(pid: pids[a])

            if debt > 0.0 {
                let postRebalanceHF = effectiveCollateral / debt
                // Track lowest HF (use pre-rebalance to capture the actual low point)
                if preRebalanceHF < lowestHF && preRebalanceHF > 0.0 {
                    lowestHF = preRebalanceHF
                }

                // Log weekly + at price extremes
                // Show both pre and post values to see rebalance effects:
                //   HF: position health factor (triggers at <1.1 or >1.5)
                //   VR: vault ratio (triggers at <0.95 or >1.05)
                if a == 0 && (day % 7 == 0 || absolutePrice == lowestPrice || absolutePrice == highestPrice) {
                    log("  [day \(day)] \(dates[day]) price=$\(absolutePrice) yt=\(ytPrice) HF=\(preRebalanceHF)->\(postRebalanceHF) VR=\(preVaultRatio)->\(postVaultRatio) vaultRebalances=\(dayVaultRebalances) positionRebalances=\(dayPositionRebalances)")
                }

                // Liquidation occurs when effectiveHF < 1.0 (check pre-rebalance)
                if preRebalanceHF < 1.0 && preRebalanceHF > 0.0 {
                    liquidationCount = liquidationCount + 1
                    log("  *** LIQUIDATION agent=\(a) on day \(day) (\(dates[day]))! HF=\(preRebalanceHF) ***")
                }
            }
            a = a + 1
        }

        previousBTCPrice = absolutePrice
        day = day + 1
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
    let finalYtPrice = ytPriceAtDay(prices.length - 1)
    // Compute effective HF to match contract's rebalancing logic
    let finalEffectiveHF = (finalBTCCollateral * previousBTCPrice * collateralFactor) / finalDebt

    // P&L: net equity = collateral_value + yt_value - debt (all in PYUSD0 terms)
    let collateralValue = finalBTCCollateral * previousBTCPrice
    let ytValue = finalYieldTokens * finalYtPrice
    let netEquity = collateralValue + ytValue - finalDebt
    let initialDeposit = fundingPerAgent * initialPrice

    // UFix64 is unsigned, so track sign separately to avoid underflow
    let profit = netEquity >= initialDeposit
    let pnlAbs = profit ? (netEquity - initialDeposit) : (initialDeposit - netEquity)
    let pnlPctAbs = pnlAbs / initialDeposit
    let pnlSign = profit ? "+" : "-"

    let netEquityBTC = netEquity / previousBTCPrice
    let btcProfit = netEquityBTC >= fundingPerAgent
    let pnlBTCAbs = btcProfit ? (netEquityBTC - fundingPerAgent) : (fundingPerAgent - netEquityBTC)
    let pnlPctBTCAbs = pnlBTCAbs / fundingPerAgent
    let pnlBTCSign = btcProfit ? "+" : "-"

    let priceUp = previousBTCPrice >= initialPrice
    let priceChangeAbs = priceUp ? (previousBTCPrice - initialPrice) : (initialPrice - previousBTCPrice)
    let priceChangePct = priceChangeAbs / initialPrice
    let priceChangeSign = priceUp ? "+" : "-"

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(numAgents)")
    log("Days simulated:      \(prices.length)")
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
    log("Final collateral:    \(finalBTCCollateral) BTC (value: \(collateralValue) PYUSD0)")
    log("Final debt:          \(finalDebt) PYUSD0")
    log("Final yield tokens:  \(finalYieldTokens) (value: \(ytValue) PYUSD0 @ yt=\(finalYtPrice))")
    log("")
    log("--- P&L ---")
    log("Initial deposit:     \(fundingPerAgent) BTC (~\(fundingPerAgent * initialPrice) PYUSD0)")
    log("Net equity (PYUSD0): \(netEquity) (P&L: \(pnlSign)\(pnlAbs), \(pnlSign)\(pnlPctAbs))")
    log("Net equity (BTC):    \(netEquityBTC) (P&L: \(pnlBTCSign)\(pnlBTCAbs), \(pnlBTCSign)\(pnlPctBTCAbs))")
    log("===========================\n")

    Test.assertEqual(btc_daily_2025_expectedLiquidationCount, liquidationCount)
    Test.assert(finalEffectiveHF > 1.0, message: "Expected final effective HF > 1.0 but got \(finalEffectiveHF)")
    Test.assert(lowestHF > 1.0, message: "Expected lowest effective HF > 1.0 but got \(lowestHF)")

    log("=== TEST PASSED: Zero liquidations over 1 year of real BTC prices (\(numAgents) agents) ===")
}
