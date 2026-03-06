#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"
import "flash_crash_moderate_helpers.cdc"

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

// Number of agents to simulate (adjust to control test duration)
access(all) let numAgents = 1

// Funding per agent (FLOW)
access(all) let fundingPerAgent: UFix64 = 1000.0

// Initial FLOW price from fixture (used to normalize prices to a ratio)
access(all) let initialPrice: UFix64 = flash_crash_moderate_prices[0]

// YT pricing: ERC4626 vault share price with deterministic 10% APR
access(all) let yieldAPR: UFix64 = flash_crash_moderate_constants.yieldAPR
access(all) let minutesPerYear: UFix64 = 525600.0

// ============================================================================
// SETUP
// ============================================================================

access(all)
fun setup() {
    deployContractsForFork()

    // Initialize all Uniswap V3 pools at 1:1 price
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

/// Normalize a fixture price to a ratio relative to the initial price.
/// e.g. 80000 / 100000 = 0.8
access(all) fun normalizePrice(_ absolutePrice: UFix64): UFix64 {
    return absolutePrice / initialPrice
}

/// Compute deterministic YT (ERC4626 vault share) price at a given minute.
/// price = 1.0 + yieldAPR * (minute / minutesPerYear)
access(all) fun ytPriceAtMinute(_ minute: Int): UFix64 {
    return 1.0 + yieldAPR * (UFix64(minute) / minutesPerYear)
}

/// Update all prices for a given simulation tick.
/// Sets BandOracle FLOW price, Uniswap V3 pool prices, and ERC4626 vault share price.
access(all) fun applyPriceTick(flowPrice: UFix64, ytPrice: UFix64, user: Test.TestAccount) {
    // BandOracle: FLOW price
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "FLOW": flowPrice,
        "USD": 1.0
    })

    // PYUSD0/WFLOW pool: 1 WFLOW = flowPrice PYUSD0
    // When flowPrice < 1.0, deficit rebalance sells FUSDEV→PYUSD0→WFLOW
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

    // MOET/FUSDEV pool: price depends on YT price
    // 1 FUSDEV = ytPrice MOET
    if flowPrice < 1.0 {
        // Deficit: swaps FUSDEV→MOET (reverse)
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
        // Surplus: swaps MOET→FUSDEV (forward)
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

    // ERC4626 vault share price (YT)
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
// TEST: Flash Crash Moderate — Zero Liquidations
// ============================================================================

access(all)
fun test_FlashCrashModerate_ZeroLiquidations() {
    let prices = flash_crash_moderate_prices

    // Create agents — each gets their own account, yield vault, and ALP position
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

    log("\n=== FLASH CRASH MODERATE SIMULATION ===")
    log("Agents: \(numAgents)")
    log("Funding per agent: \(fundingPerAgent) FLOW")
    log("Duration: \(flash_crash_moderate_durationMinutes) minutes")
    log("Price points: \(prices.length)")
    log("Notes: \(flash_crash_moderate_notes)")

    // Track state
    var liquidationCount = 0
    var rebalanceCount = 0
    var previousNormalizedPrice: UFix64 = 1.0
    var lowestPrice: UFix64 = initialPrice
    var lowestHF: UFix64 = 100.0 // start high

    // Record start timestamp so we can advance to minute-aligned times
    let startTimestamp = getCurrentBlockTimestamp()

    // Simulation loop — only act on price changes to avoid redundant work
    var step = 0
    while step < prices.length {
        let absolutePrice = prices[step]
        let normalizedPrice = normalizePrice(absolutePrice)
        let ytPrice = ytPriceAtMinute(step)

        // Track lowest price
        if absolutePrice < lowestPrice {
            lowestPrice = absolutePrice
        }

        // Only update state when price has changed (skip flat regions)
        if normalizedPrice != previousNormalizedPrice {
            // Advance blockchain time to match the tick's minute offset
            let expectedTimestamp = startTimestamp + UFix64(step) * 60.0
            let currentTimestamp = getCurrentBlockTimestamp()
            if expectedTimestamp > currentTimestamp {
                Test.moveTime(by: Fix64(expectedTimestamp - currentTimestamp))
            }

            // --- PROFILING: log wall-clock timestamps between steps ---
            let profileTick = rebalanceCount < 5 // only profile first 5 ticks
            if profileTick { log("  PROFILE [t=\(step)m] START") }

            // 1. BandOracle price
            setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
                "FLOW": normalizedPrice,
                "USD": 1.0
            })
            if profileTick { log("  PROFILE [t=\(step)m] after setBandOraclePrices") }

            // 2. WFLOW/PYUSD0 pool
            setPoolToPrice(
                factoryAddress: factoryAddress,
                tokenAAddress: wflowAddress,
                tokenBAddress: pyusd0Address,
                fee: 3000,
                priceTokenBPerTokenA: feeAdjustedPrice(UFix128(normalizedPrice), fee: 3000, reverse: true),
                tokenABalanceSlot: wflowBalanceSlot,
                tokenBBalanceSlot: pyusd0BalanceSlot,
                signer: coaOwnerAccount
            )
            if profileTick { log("  PROFILE [t=\(step)m] after setPoolToPrice WFLOW/PYUSD0") }

            // 3. MOET/FUSDEV pool
            if normalizedPrice < 1.0 {
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
            if profileTick { log("  PROFILE [t=\(step)m] after setPoolToPrice MOET/FUSDEV") }

            // 4. ERC4626 vault share price
            setVaultSharePrice(
                vaultAddress: morphoVaultAddress,
                assetAddress: pyusd0Address,
                assetBalanceSlot: pyusd0BalanceSlot,
                totalSupplySlot: morphoVaultTotalSupplySlot,
                vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
                priceMultiplier: ytPrice,
                signer: users[0]
            )
            if profileTick { log("  PROFILE [t=\(step)m] after setVaultSharePrice") }

            // 5. Rebalance all agents
            var a = 0
            while a < numAgents {
                rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: true, beFailed: false)
                if profileTick { log("  PROFILE [t=\(step)m] after rebalanceYieldVault agent=\(a)") }
                rebalancePosition(signer: flowALPAccount, pid: pids[a], force: true, beFailed: false)
                if profileTick { log("  PROFILE [t=\(step)m] after rebalancePosition agent=\(a)") }
                a = a + 1
            }
            rebalanceCount = rebalanceCount + 1

            // 6. Check health factor for all agents
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

                    // Log at critical moments (only agent 0 to avoid spam)
                    if a == 0 {
                        log("  [t=\(step)m] price=\(absolutePrice) yt=\(ytPrice) HF=\(hf) collateral=\(flowCollateralValue) debt=\(debt)")
                    }

                    // Check for liquidation (HF < 1.0)
                    if hf < 1.0 {
                        liquidationCount = liquidationCount + 1
                        log("  *** LIQUIDATION agent=\(a) at t=\(step)m! HF=\(hf) ***")
                    }
                }
                a = a + 1
            }
            if profileTick { log("  PROFILE [t=\(step)m] after HF checks") }

            previousNormalizedPrice = normalizedPrice
        }

        step = step + 1
    }

    // Final state (report agent 0 as representative)
    let finalFlowCollateral = getFlowCollateralFromPosition(pid: pids[0])
    let finalDebt = getMOETDebtFromPosition(pid: pids[0])
    let finalYieldTokens = getAutoBalancerBalance(id: vaultIds[0])!
    let finalNormalizedPrice = normalizePrice(prices[prices.length - 1])
    let finalHF = (finalFlowCollateral * finalNormalizedPrice) / finalDebt

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(numAgents)")
    log("Rebalance events:    \(rebalanceCount)")
    log("Liquidation count:   \(liquidationCount)")
    log("Lowest FLOW price:   \(lowestPrice)")
    log("Lowest HF observed:  \(lowestHF)")
    log("Final FLOW price:    \(finalNormalizedPrice)")
    log("Final HF (agent 0):  \(finalHF)")
    log("Final collateral:    \(finalFlowCollateral) FLOW")
    log("Final debt:          \(finalDebt) MOET")
    log("Final yield tokens:  \(finalYieldTokens)")
    log("===========================\n")

    // PASS CRITERIA: Zero liquidations across all agents
    Test.assertEqual(flash_crash_moderate_expectedLiquidationCount, liquidationCount)
    Test.assert(finalHF > 1.0, message: "Expected final HF > 1.0 but got \(finalHF)")
    Test.assert(lowestHF > 1.0, message: "Expected lowest HF > 1.0 but got \(lowestHF)")

    log("=== TEST PASSED: Zero liquidations under 20% flash crash (\(numAgents) agents) ===")
}
