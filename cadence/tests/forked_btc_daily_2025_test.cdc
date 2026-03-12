#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "btc_daily_2025_helpers.cdc"

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

access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"

// ============================================================================
// VAULT & TOKEN ADDRESSES
// ============================================================================

access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

access(all) let moetBalanceSlot = 0 as UInt256
access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wflowBalanceSlot = 3 as UInt256

access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

// ============================================================================
// SIMULATION CONFIG
// ============================================================================

access(all) let numAgents = 1

access(all) let fundingPerAgent = 1000.0

access(all) let initialPrice = btc_daily_2025_prices[0]

access(all) let yieldAPR = btc_daily_2025_constants.yieldAPR
access(all) let daysPerYear = 365.0
access(all) let secondsPerDay = 86400.0

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

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

    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": 1.0,
        "USD": 1.0
    })

    let reserveAmount = 100_000_00.0
    transferFlow(signer: whaleFlowAccount, recipient: flowALPAccount.address, amount: reserveAmount)
    mintMoet(signer: flowALPAccount, to: flowALPAccount.address, amount: reserveAmount, beFailed: false)

    transferFlow(signer: whaleFlowAccount, recipient: flowYieldVaultsAccount.address, amount: reserveAmount)
    transferFlow(signer: whaleFlowAccount, recipient: coaOwnerAccount.address, amount: reserveAmount)
}

// ============================================================================
// HELPERS
// ============================================================================

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

access(all) fun normalizePrice(_ absolutePrice: UFix64): UFix64 {
    return absolutePrice / initialPrice
}

/// Compute deterministic YT (ERC4626 vault share) price at a given day.
/// price = 1.0 + yieldAPR * (day / 365)
access(all) fun ytPriceAtDay(_ day: Int): UFix64 {
    return 1.0 + yieldAPR * (UFix64(day) / daysPerYear)
}

/// Update all prices for a given simulation day.
access(all) fun applyPriceTick(flowPrice: UFix64, ytPrice: UFix64, user: Test.TestAccount) {
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPrice,
        "USD": 1.0
    })

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

    if flowPrice < 1.0 {
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: moetAddress,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(ytPrice), fee: 100, reverse: true),
            tokenABalanceSlot: moetBalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )
    } else {
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: moetAddress,
            tokenBAddress: morphoVaultAddress,
            fee: 100,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(ytPrice), fee: 100, reverse: false),
            tokenABalanceSlot: moetBalanceSlot,
            tokenBBalanceSlot: fusdevBalanceSlot,
            signer: coaOwnerAccount
        )
    }

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

    var i = 0
    while i < numAgents {
        let user = Test.createAccount()
        transferFlow(signer: whaleFlowAccount, recipient: user.address, amount: fundingPerAgent)
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
            vaultIdentifier: flowTokenIdentifier,
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
    log("Funding per agent: \(fundingPerAgent) FLOW")
    log("Duration: \(btc_daily_2025_durationDays) days")
    log("Price points: \(prices.length)")
    log("Initial BTC price: $\(prices[0])")
    log("Notes: \(btc_daily_2025_notes)")

    var liquidationCount = 0
    var rebalanceCount = 0
    var previousNormalizedPrice = 1.0
    var lowestPrice = initialPrice
    var highestPrice = initialPrice
    var lowestHF = 100.0

    let startTimestamp = getCurrentBlockTimestamp()

    var day = 0
    while day < prices.length {
        let absolutePrice = prices[day]
        let normalizedPrice = normalizePrice(absolutePrice)
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
        applyPriceTick(flowPrice: normalizedPrice, ytPrice: ytPrice, user: users[0])

        // Potentially rebalance all agents (not forced)
        var a = 0
        while a < numAgents {
            rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: false, beFailed: false)
            rebalancePosition(signer: flowALPAccount, pid: pids[a], force: false, beFailed: false)
            a = a + 1
        }
        rebalanceCount = rebalanceCount + 1

        // Check health factors
        a = 0
        while a < numAgents {
            let flowCollateral = getFlowCollateralFromPosition(pid: pids[a])
            let flowCollateralValue = flowCollateral * normalizedPrice
            let debt = getMOETDebtFromPosition(pid: pids[a])

            if debt > 0.0 {
                let hf = flowCollateralValue / debt
                if hf < lowestHF {
                    lowestHF = hf
                }

                // Log weekly + at price extremes
                if a == 0 && (day % 7 == 0 || absolutePrice == lowestPrice || absolutePrice == highestPrice) {
                    log("  [day \(day)] \(dates[day]) price=$\(absolutePrice) ratio=\(normalizedPrice) yt=\(ytPrice) HF=\(hf) collateral=\(flowCollateralValue) debt=\(debt)")
                }

                if hf < 1.0 {
                    liquidationCount = liquidationCount + 1
                    log("  *** LIQUIDATION agent=\(a) on day \(day) (\(dates[day]))! HF=\(hf) ***")
                }
            }
            a = a + 1
        }

        previousNormalizedPrice = normalizedPrice
        day = day + 1
    }

    // Final state
    let finalFlowCollateral = getFlowCollateralFromPosition(pid: pids[0])
    let finalDebt = getMOETDebtFromPosition(pid: pids[0])
    let finalYieldTokens = getAutoBalancerBalance(id: vaultIds[0])!
    let finalNormalizedPrice = normalizePrice(prices[prices.length - 1])
    let finalYtPrice = ytPriceAtDay(prices.length - 1)
    let finalHF = (finalFlowCollateral * finalNormalizedPrice) / finalDebt

    // P&L: net equity = collateral_value + yt_value - debt (all in stablecoin/MOET terms)
    let collateralValueMOET = finalFlowCollateral * finalNormalizedPrice
    let ytValueMOET = finalYieldTokens * finalYtPrice
    let netEquityMOET = collateralValueMOET + ytValueMOET - finalDebt
    let initialDepositMOET = fundingPerAgent

    // UFix64 is unsigned, so track sign separately to avoid underflow
    let moetProfit = netEquityMOET >= initialDepositMOET
    let pnlMOETAbs = moetProfit ? (netEquityMOET - initialDepositMOET) : (initialDepositMOET - netEquityMOET)
    let pnlPctMOETAbs = pnlMOETAbs / initialDepositMOET
    let pnlMOETSign = moetProfit ? "+" : "-"

    let netEquityFLOW = netEquityMOET / finalNormalizedPrice
    let flowProfit = netEquityFLOW >= fundingPerAgent
    let pnlFLOWAbs = flowProfit ? (netEquityFLOW - fundingPerAgent) : (fundingPerAgent - netEquityFLOW)
    let pnlPctFLOWAbs = pnlFLOWAbs / fundingPerAgent
    let pnlFLOWSign = flowProfit ? "+" : "-"

    let priceUp = finalNormalizedPrice >= 1.0
    let priceChangePctAbs = priceUp ? (finalNormalizedPrice - 1.0) : (1.0 - finalNormalizedPrice)
    let priceChangeSign = priceUp ? "+" : "-"

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(numAgents)")
    log("Days simulated:      \(prices.length)")
    log("Rebalance events:    \(rebalanceCount)")
    log("Liquidation count:   \(liquidationCount)")
    log("")
    log("--- Price ---")
    log("Initial BTC price:   $\(initialPrice)")
    log("Lowest BTC price:    $\(lowestPrice)")
    log("Highest BTC price:   $\(highestPrice)")
    log("Final BTC price:     $\(prices[prices.length - 1])")
    log("Price change:        \(priceChangeSign)\(priceChangePctAbs)")
    log("")
    log("--- Position ---")
    log("Lowest HF observed:  \(lowestHF)")
    log("Final HF (agent 0):  \(finalHF)")
    log("Final collateral:    \(finalFlowCollateral) FLOW (value: \(collateralValueMOET) MOET)")
    log("Final debt:          \(finalDebt) MOET")
    log("Final yield tokens:  \(finalYieldTokens) (value: \(ytValueMOET) MOET @ yt=\(finalYtPrice))")
    log("")
    log("--- P&L ---")
    log("Initial deposit:     \(fundingPerAgent) FLOW")
    log("Net equity (MOET):   \(netEquityMOET) (P&L: \(pnlMOETSign)\(pnlMOETAbs), \(pnlMOETSign)\(pnlPctMOETAbs))")
    log("Net equity (FLOW):   \(netEquityFLOW) (P&L: \(pnlFLOWSign)\(pnlFLOWAbs), \(pnlFLOWSign)\(pnlPctFLOWAbs))")
    log("===========================\n")

    Test.assertEqual(btc_daily_2025_expectedLiquidationCount, liquidationCount)
    Test.assert(finalHF > 1.0, message: "Expected final HF > 1.0 but got \(finalHF)")
    Test.assert(lowestHF > 1.0, message: "Expected lowest HF > 1.0 but got \(lowestHF)")

    log("=== TEST PASSED: Zero liquidations over 1 year of real BTC prices (\(numAgents) agents) ===")
}
