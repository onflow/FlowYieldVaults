#test_fork(network: "mainnet-fork", height: 147316310)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "simulation_btc_daily_historical_helpers.cdc"

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

// PYUSD0 on Flow EVM (bridged token)
access(all) let PYUSD0_TOKEN_ID = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"

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

access(all) let fundingPerAgent = 1.0
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

// Liquidation parameters.
// liquidationTargetHF: the max post-liquidation effective HF the contract allows (FlowALPv0 default: 1.05).
// liquidationDiscount: fraction of fair-value BTC to seize (must be < 1.0 to beat the DEX quote).
access(all) let liquidationTargetHF = 1.05
access(all) let liquidationDiscount = 0.95

// Position health factor thresholds shared across all BTC historical simulations.
access(all) let simInitialHF: UFix64 = 1.3
access(all) let simMinHF: UFix64 = 1.1
access(all) let simTargetHF: UFix64 = 1.3
access(all) let simMaxHF: UFix64 = 1.5

access(all) var snapshot: UInt64 = 0

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

    snapshot = getCurrentBlockHeight()
}

access(all)
fun setupInitialState() {
    // it removes all the existing scheduled transactions, it is useful to speed up the tests,
    // because otherwise, the existing 41 scheduled transactions will be executed every time we
    // move the time forward, and each taking about 40ms, which make the tests very slow
    // after 365 days of simulation, the total delay would be 10mins.
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
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

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

/// Compute deterministic YT (ERC4626 vault share) price at a given day.
/// price = 1.0 + yieldAPR * (day / 365)
access(all) fun ytPriceAtDay(_ day: Int, yieldAPR: UFix64): UFix64 {
    return 1.0 + yieldAPR * (UFix64(day) / daysPerYear)
}

/// Update all prices for a given simulation day.
access(all) fun applyPriceTick(
    btcPrice: UFix64,
    ytPrice: UFix64,
    user: Test.TestAccount,
    pools: {String: SimPool}
) {
    let btcPool = pools["pyusd_btc"]!
    let ytPool = pools["moet_fusdev"]!

    setPoolToPriceWithTVL(
        factoryAddress: factoryAddress,
        tokenAAddress: wbtcAddress,
        tokenBAddress: pyusd0Address,
        fee: UInt64(btcPool.feeTier * 1_000_000.0),
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
        fee: UInt64(ytPool.feeTier * 1_000_000.0),
        priceTokenBPerTokenA: UFix128(ytPrice),
        tokenABalanceSlot: pyusd0BalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        tvl: ytPool.size,
        concentration: ytPool.concentration,
        tokenBPriceUSD: ytPrice,
        signer: coaOwnerAccount
    )

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

    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        priceMultiplier: ytPrice,
        signer: user
    )

    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": btcPrice,
        "USD": 1.0,
        "PYUSD": 1.0
    })
}

// ============================================================================
// CORE SIMULATION
// ============================================================================

access(all)
fun runDailySimulation(
    scenarioName: String,
    prices: [UFix64],
    dates: [String],
    agents: [SimAgent],
    pools: {String: SimPool},
    constants: SimConstants,
    expectedLiquidationCount: Int,
    durationDays: Int,
    notes: String,
    initialHF: UFix64,
    minHF: UFix64,
    targetHF: UFix64,
    maxHF: UFix64
) {
    safeReset()
    setupInitialState()

    let initialPrice = prices[0]
    let numAgents = agents[0].count
    let yieldAPR = constants.yieldAPR

    // Create agents
    let users: [Test.TestAccount] = []
    let pids: [UInt64] = []
    let vaultIds: [UInt64] = []

    // Apply initial pricing
    applyPriceTick(btcPrice: initialPrice, ytPrice: ytPriceAtDay(0, yieldAPR: yieldAPR), user: coaOwnerAccount, pools: pools)

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

        let agent = agents[i]

        // forced initial rebalance needs infinite liquidity
        setInfiniteLiquidity()

        // Step 1: Coerce position to the desired initial HF.
        // Set temporary health params with targetHealth=initialHF, then force-rebalance.
        // This makes the on-chain rebalancer push the position to exactly initialHF.
        setPositionHealthParams(
            signer: flowALPAccount,
            pid: pid,
            targetHealth: initialHF,
            minHealth: initialHF - 0.01,
            maxHealth: initialHF + 0.01
        )
        rebalancePosition(signer: flowALPAccount, pid: pid, force: true, beFailed: false)

        // Step 2: Set the real health thresholds for the simulation.
        setPositionHealthParams(
            signer: flowALPAccount,
            pid: pid,
            targetHealth: targetHF,
            minHealth: minHF,
            maxHealth: maxHF
        )

        users.append(user)
        pids.append(pid)
        vaultIds.append(vaultId)

        log("  Agent \(i): pid=\(pid) vaultId=\(vaultId)")
        i = i + 1
    }

    log("\n=== \(scenarioName) SIMULATION ===")
    log("Agents: \(numAgents)")
    log("Funding per agent: \(fundingPerAgent) BTC (~\(fundingPerAgent * initialPrice) PYUSD0)")
    log("Duration: \(durationDays) days")
    log("Price points: \(prices.length)")
    log("Initial BTC price: $\(prices[0])")
    log("Notes: \(notes)")
    log("")
    log("Rebalance Triggers:")
    log("  HF (Position): triggers when HF < \(minHF) or HF > \(maxHF), rebalances to HF = \(targetHF)")
    log("  VR (Vault):    triggers when VR < \(vaultLowerThreshold) or VR > \(vaultUpperThreshold), rebalances to VR ~ 1.0")

    // Liquidator account: pre-funded with PYUSD0 so it can attempt manual liquidations
    let liquidator = Test.createAccount()
    transferFlow(signer: whaleFlowAccount, recipient: liquidator.address, amount: 10.0)
    setupGenericVault(signer: liquidator, vaultIdentifier: PYUSD0_TOKEN_ID)
    setupGenericVault(signer: liquidator, vaultIdentifier: WBTC_TOKEN_ID)
    let liquidatorReserve = 100_000.0
    mintPYUSD0(signer: liquidator, amount: liquidatorReserve)

    var liquidationCount = 0
    var previousBTCPrice = initialPrice
    var lowestPrice = initialPrice
    var highestPrice = initialPrice
    var lowestHF = 100.0
    // Snapshot event counts after agent setup so day 0 doesn't count setup rebalances
    var prevVaultRebalanceCount = Test.eventsOfType(Type<DeFiActions.Rebalanced>()).length
    var prevPositionRebalanceCount = Test.eventsOfType(Type<FlowALPv0.Rebalanced>()).length

    let startTimestamp = getCurrentBlockTimestamp()

    var day = 0
    while day < prices.length {
        let absolutePrice = prices[day]
        let ytPrice = ytPriceAtDay(day, yieldAPR: yieldAPR)

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
        applyPriceTick(btcPrice: absolutePrice, ytPrice: ytPrice, user: users[0], pools: pools)

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

            // Liquidation occurs when effectiveHF < 1.0 (check pre-rebalance)
            if preRebalanceHF < 1.0 && preRebalanceHF > 0.0 {
                liquidationCount = liquidationCount + 1
                log("  *** LIQUIDATION agent=\(a) on day \(day) (\(dates[day]))! HF=\(preRebalanceHF) price=\(absolutePrice) previousPrice=\(previousBTCPrice)***")

                let debt = getPYUSD0DebtFromPosition(pid: pids[a])
                let btcCollateral = getBTCCollateralFromPosition(pid: pids[a])

                // Compute how much debt to repay to bring position to liquidationTargetHF.
                //
                //   postHF = (Ce_pre - Ce_seize) / (De_pre - repayAmount)
                //   Ce_pre = btcCollateral * btcPrice * collateralFactor
                //   De_pre = debt  (borrowFactor=1, PYUSD0 price=1)
                //   seizeAmount = repayAmount / btcPrice * discount  (must beat DEX)
                //   Ce_seize = seizeAmount * btcPrice * collateralFactor = repayAmount * discount * collateralFactor
                //
                // Solving for repayAmount:
                //   repayAmount = (Ce_pre - targetHF * De_pre) / (discount * collateralFactor - targetHF)

                // leave a small buffer so liquidation succeeds (constraint says post liquidation HF <= liquidationTargetHF)
                let targetHF = liquidationTargetHF - 0.01
                let Ce_pre = btcCollateral * absolutePrice * collateralFactor
                let De_pre = debt
                let numerator = targetHF * De_pre - Ce_pre
                let denominator = targetHF - liquidationDiscount * collateralFactor
                var repayAmount = numerator / denominator

                // Clamp: can't repay more than the position's debt
                if repayAmount > debt {
                    repayAmount = debt
                }

                let seizeAmount = repayAmount / absolutePrice * liquidationDiscount

                // Register/update MockDexSwapper pair so manualLiquidation's DEX price check passes
                let pyusd0StoragePath = StoragePath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")!
                let setDexRes = _executeTransaction(
                    "../../lib/FlowALP/cadence/tests/transactions/mock-dex-swapper/set_mock_dex_price_for_pair.cdc",
                    [WBTC_TOKEN_ID, PYUSD0_TOKEN_ID, pyusd0StoragePath, absolutePrice],
                    liquidator
                )
                if setDexRes.error != nil {
                    log("    MockDexSwapper setup failed: \(setDexRes.error!.message)")
                }

                let liqRes = _executeTransaction(
                    "../../lib/FlowALP/cadence/transactions/flow-alp/pool-management/manual_liquidation.cdc",
                    [pids[a], PYUSD0_TOKEN_ID, WBTC_TOKEN_ID, seizeAmount, repayAmount],
                    liquidator
                )
                if liqRes.error == nil {
                    let Ce_post = Ce_pre - seizeAmount * absolutePrice * collateralFactor
                    let De_post = De_pre - repayAmount
                    let expectedPostHF = Ce_post / De_post
                    log("    Liquidation succeeded: repaid \(repayAmount) PYUSD0, seized \(seizeAmount) BTC, expected post-HF=\(expectedPostHF)")
                } else {
                    log("    Liquidation failed: \(liqRes.error!.message)")
                }
            }

            a = a + 1
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

            // Log weekly + at price extremes
            // Show both pre and post values to see rebalance effects:
            //   HF: position health factor (triggers at <1.1 or >1.5)
            //   VR: vault ratio (triggers at <0.95 or >1.05)
            if a == 0 && (day % 7 == 0 || absolutePrice == lowestPrice || absolutePrice == highestPrice) {
                log("  [day \(day)] \(dates[day]) price=$\(absolutePrice) yt=\(ytPrice) HF=\(preRebalanceHF)->\(postRebalanceHF) VR=\(preVaultRatio)->\(postVaultRatio) vaultRebalances=\(dayVaultRebalances) positionRebalances=\(dayPositionRebalances)")
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
    let finalYtPrice = ytPriceAtDay(prices.length - 1, yieldAPR: yieldAPR)
    // Compute effective HF to match contract's rebalancing logic
    let finalEffectiveHF = (finalBTCCollateral * previousBTCPrice * collateralFactor) / finalDebt

    // Final position values in USD (PYUSD0 ~ 1 USD)
    let finalCollateralValueUSD = finalBTCCollateral * previousBTCPrice
    let finalYtValueUSD = finalYieldTokens * finalYtPrice
    let finalNetEquityUSD = finalCollateralValueUSD + finalYtValueUSD - finalDebt
    let initialDepositUSD = fundingPerAgent * initialPrice

    // P&L vs initial deposit
    let usdProfit = finalNetEquityUSD >= initialDepositUSD
    let pnlUSDAbs = usdProfit ? (finalNetEquityUSD - initialDepositUSD) : (initialDepositUSD - finalNetEquityUSD)
    let pnlPctUSDAbs = pnlUSDAbs / initialDepositUSD
    let pnlUSDSign = usdProfit ? "+" : "-"

    let netEquityBTC = finalNetEquityUSD / previousBTCPrice
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
    log("Final collateral:    \(finalBTCCollateral) BTC ($\(finalCollateralValueUSD))")
    log("Final debt:          \(finalDebt) PYUSD0")
    log("Final yield tokens:  \(finalYieldTokens) ($\(finalYtValueUSD) @ yt=\(finalYtPrice))")
    log("")
    log("--- P&L ---")
    log("Initial deposit:     \(fundingPerAgent) BTC (~$\(initialDepositUSD))")
    log("Net equity (USD):    $\(finalNetEquityUSD) (P&L: \(pnlUSDSign)$\(pnlUSDAbs), \(pnlUSDSign)\(pnlPctUSDAbs))")
    log("Net equity (BTC):    \(netEquityBTC) BTC (P&L: \(pnlBTCSign)\(pnlBTCAbs) BTC, \(pnlBTCSign)\(pnlPctBTCAbs))")
    log("===========================\n")

    Test.assertEqual(expectedLiquidationCount, liquidationCount)
    if expectedLiquidationCount == 0 {
        Test.assert(finalEffectiveHF > 1.0, message: "Expected final HF > 1.0 but got \(finalEffectiveHF)")
        Test.assert(lowestHF > 1.0, message: "Expected lowest HF > 1.0 but got \(lowestHF)")
    }

    log("=== TEST PASSED: \(liquidationCount) liquidations (expected \(expectedLiquidationCount)) over \(prices.length) days of real BTC prices (\(numAgents) agents) ===")
}

// ============================================================================
// TEST CASES
// Edit the json files to change the simulation parameters. These are in the scripts/simulations folder.
// Then run the generate_fixture.py script to generate the helpers.cdc file.
// ============================================================================

access(all)
fun test_BTC_2021() {
    runDailySimulation(
        scenarioName: "BTC Daily 2021 Mixed",
        prices: btc_daily_2021_mixed_prices,
        dates: btc_daily_2021_mixed_dates,
        agents: btc_daily_2021_mixed_agents,
        pools: btc_daily_2021_mixed_pools,
        constants: btc_daily_2021_mixed_constants,
        expectedLiquidationCount: btc_daily_2021_mixed_expectedLiquidationCount,
        durationDays: btc_daily_2021_mixed_durationDays,
        notes: btc_daily_2021_mixed_notes,
        initialHF: simInitialHF,
        minHF: simMinHF,
        targetHF: simTargetHF,
        maxHF: simMaxHF
    )
}

access(all)
fun test_BTC_2022() {
    // Example of HFs that would encounter 0 liquidations in the 2022 bear market:
    // initialHF: 1.2, minHF: 1.1, targetHF: 1.2, maxHF: 1.3
    runDailySimulation(
        scenarioName: "BTC Daily 2022 Bear",
        prices: btc_daily_2022_bear_prices,
        dates: btc_daily_2022_bear_dates,
        agents: btc_daily_2022_bear_agents,
        pools: btc_daily_2022_bear_pools,
        constants: btc_daily_2022_bear_constants,
        expectedLiquidationCount: btc_daily_2022_bear_expectedLiquidationCount,
        durationDays: btc_daily_2022_bear_durationDays,
        notes: btc_daily_2022_bear_notes,
        initialHF: simInitialHF,
        minHF: simMinHF,
        targetHF: simTargetHF,
        maxHF: simMaxHF
    )
}

access(all)
fun test_BTC_2023() {
    runDailySimulation(
        scenarioName: "BTC Daily 2023 Bull",
        prices: btc_daily_2023_bull_prices,
        dates: btc_daily_2023_bull_dates,
        agents: btc_daily_2023_bull_agents,
        pools: btc_daily_2023_bull_pools,
        constants: btc_daily_2023_bull_constants,
        expectedLiquidationCount: btc_daily_2023_bull_expectedLiquidationCount,
        durationDays: btc_daily_2023_bull_durationDays,
        notes: btc_daily_2023_bull_notes,
        initialHF: simInitialHF, minHF: simMinHF, targetHF: simTargetHF, maxHF: simMaxHF
    )
}

access(all)
fun test_BTC_2024() {
    runDailySimulation(
        scenarioName: "BTC Daily 2024 Bull",
        prices: btc_daily_2024_bull_prices,
        dates: btc_daily_2024_bull_dates,
        agents: btc_daily_2024_bull_agents,
        pools: btc_daily_2024_bull_pools,
        constants: btc_daily_2024_bull_constants,
        expectedLiquidationCount: btc_daily_2024_bull_expectedLiquidationCount,
        durationDays: btc_daily_2024_bull_durationDays,
        notes: btc_daily_2024_bull_notes,
        initialHF: simInitialHF, minHF: simMinHF, targetHF: simTargetHF, maxHF: simMaxHF
    )
}

access(all)
fun test_BTC_2025() {
    runDailySimulation(
        scenarioName: "BTC Daily 2025 Mixed",
        prices: btc_daily_2025_mixed_prices,
        dates: btc_daily_2025_mixed_dates,
        agents: btc_daily_2025_mixed_agents,
        pools: btc_daily_2025_mixed_pools,
        constants: btc_daily_2025_mixed_constants,
        expectedLiquidationCount: btc_daily_2025_mixed_expectedLiquidationCount,
        durationDays: btc_daily_2025_mixed_durationDays,
        notes: btc_daily_2025_mixed_notes,
        initialHF: simInitialHF, minHF: simMinHF, targetHF: simTargetHF, maxHF: simMaxHF
    )
}
