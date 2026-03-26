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
access(all) let moetAddress = "0x213979bB8A9A86966999b3AA797C1fcf3B967ae2"
access(all) let wbtcAddress = "0x717dae2baf7656be9a9b01dee31d571a9d4c9579"

// ============================================================================
// STORAGE SLOT CONSTANTS
// ============================================================================

access(all) let moetBalanceSlot = 0 as UInt256
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
    /// How often (in seconds) to reset the MOET/FUSDEV pool price to peg.
    /// Simulates the ALM arbitrage agent from the Python sims.
    /// 0 = reset every tick
    /// 43200 = every 12h (matches Python sim ALM interval)
    access(all) let poolResetInterval: UFix64
    /// Python sim HF thresholds — for reference/logging only.
    /// TODO: These should be applied to the on-chain FlowALP Position (via Position.setMinHealth,
    /// setTargetHealth, setMaxHealth) but the Position is embedded inside FUSDEVStrategy with
    /// access(self) and no passthrough exists. Current on-chain defaults are:
    ///   minHealth=1.1, targetHealth=1.3, maxHealth=1.5
    /// Python sim values (flash crash): rebalancingHF=1.05, targetHF=1.08, initialHF=1.15
    /// To fix: either expose setters on FUSDEVStrategy, or add an EGovernance method to Pool.
    access(all) let initialHF: UFix64
    access(all) let rebalancingHF: UFix64
    access(all) let targetHF: UFix64

    init(
        prices: [UFix64],
        tickIntervalSeconds: UFix64,
        numAgents: Int,
        fundingPerAgent: UFix64,
        yieldAPR: UFix64,
        expectedLiquidationCount: Int,
        poolResetInterval: UFix64,
        initialHF: UFix64,
        rebalancingHF: UFix64,
        targetHF: UFix64
    ) {
        self.prices = prices
        self.tickIntervalSeconds = tickIntervalSeconds
        self.numAgents = numAgents
        self.fundingPerAgent = fundingPerAgent
        self.yieldAPR = yieldAPR
        self.expectedLiquidationCount = expectedLiquidationCount
        self.poolResetInterval = poolResetInterval
        self.initialHF = initialHF
        self.rebalancingHF = rebalancingHF
        self.targetHF = targetHF
    }
}

access(all) struct SimResult {
    access(all) let rebalanceCount: Int
    access(all) let liquidationCount: Int
    access(all) let lowestHF: UFix64
    access(all) let finalHF: UFix64
    access(all) let lowestPrice: UFix64
    access(all) let finalPrice: UFix64

    init(
        rebalanceCount: Int,
        liquidationCount: Int,
        lowestHF: UFix64,
        finalHF: UFix64,
        lowestPrice: UFix64,
        finalPrice: UFix64
    ) {
        self.rebalanceCount = rebalanceCount
        self.liquidationCount = liquidationCount
        self.lowestHF = lowestHF
        self.finalHF = finalHF
        self.lowestPrice = lowestPrice
        self.finalPrice = finalPrice
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

    // MOET:morphoVault (yield token pool)
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

    // MOET:PYUSD0 (routing pool)
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

    // PYUSD0:WBTC (collateral/liquidation pool) — infinite liquidity for now
    let initialBtcPrice = flash_crash_moderate_prices[0]
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wbtcAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: UFix128(initialBtcPrice),
        tokenABalanceSlot: wbtcBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": initialBtcPrice,
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

/// Update oracle, external market pool, and vault share price each tick.
/// This does NOT touch the MOET/FUSDEV pool — that's controlled by resetYieldPool().
access(all) fun applyPriceTick(btcPrice: UFix64, ytPrice: UFix64, signer: Test.TestAccount) {
    setBandOraclePrices(signer: bandOracleAccount, symbolPrices: {
        "BTC": btcPrice,
        "USD": 1.0
    })

    // PYUSD0:WBTC pool — update BTC price (infinite liquidity)
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wbtcAddress,
        tokenBAddress: pyusd0Address,
        fee: 3000,
        priceTokenBPerTokenA: UFix128(btcPrice),
        tokenABalanceSlot: wbtcBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
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

/// Reset the MOET/FUSDEV (yield token) pool price to peg.
access(all) fun resetYieldPool(ytPrice: UFix64) {
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: moetAddress,
        tokenBAddress: morphoVaultAddress,
        fee: 100,
        priceTokenBPerTokenA: UFix128(ytPrice),
        tokenABalanceSlot: moetBalanceSlot,
        tokenBBalanceSlot: fusdevBalanceSlot,
        signer: coaOwnerAccount
    )
}

// ============================================================================
// SIMULATION RUNNER
// ============================================================================

access(all) fun runSimulation(config: SimConfig): SimResult {
    let prices = config.prices
    let initialPrice = prices[0]

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

        users.append(user)
        pids.append(pid)
        vaultIds.append(vaultId)

        log("  Agent \(i): pid=\(pid) vaultId=\(vaultId)")
        i = i + 1
    }

    log("\n=== SIMULATION ===")
    log("Agents: \(config.numAgents)")
    log("Funding per agent: \(config.fundingPerAgent) BTC (~\(config.fundingPerAgent * initialPrice) MOET)")
    log("Tick interval: \(config.tickIntervalSeconds)s")
    log("Price points: \(prices.length)")

    // Run simulation
    var rebalanceCount = 0
    var liquidationCount = 0
    var lowestHF: UFix64 = 100.0
    var lowestPrice: UFix64 = 999999999.0
    var previousBTCPrice: UFix64 = initialPrice
    let startTimestamp = getCurrentBlockTimestamp()

    var step = 0
    while step < prices.length {
        let absolutePrice = prices[step]
        let ytPrice = ytPriceAtTick(step, tickIntervalSeconds: config.tickIntervalSeconds, yieldAPR: config.yieldAPR)

        if absolutePrice < lowestPrice {
            lowestPrice = absolutePrice
        }

        if absolutePrice != previousBTCPrice {
            let expectedTimestamp = startTimestamp + UFix64(step) * config.tickIntervalSeconds
            let currentTimestamp = getCurrentBlockTimestamp()
            if expectedTimestamp > currentTimestamp {
                Test.moveTime(by: Fix64(expectedTimestamp - currentTimestamp))
            }

            applyPriceTick(btcPrice: absolutePrice, ytPrice: ytPrice, signer: users[0])

            // Reset yield pool on interval (simulates ALM arb agent)
            let elapsedSeconds = UFix64(step) * config.tickIntervalSeconds
            if config.poolResetInterval == 0.0 || elapsedSeconds % config.poolResetInterval == 0.0 {
                resetYieldPool(ytPrice: ytPrice)
            }

            // Rebalance all agents
            var a = 0
            while a < config.numAgents {
                rebalanceYieldVault(signer: flowYieldVaultsAccount, id: vaultIds[a], force: false, beFailed: false)
                rebalancePosition(signer: flowALPAccount, pid: pids[a], force: false, beFailed: false)
                a = a + 1
            }
            rebalanceCount = rebalanceCount + 1

            // Check health factor for all agents
            a = 0
            while a < config.numAgents {
                let btcCollateral = getBTCCollateralFromPosition(pid: pids[a])
                let btcCollateralValue = btcCollateral * absolutePrice
                let debt = getMOETDebtFromPosition(pid: pids[a])

                if debt > 0.0 {
                    let hf = btcCollateralValue / debt
                    if hf < lowestHF {
                        lowestHF = hf
                    }

                    if a == 0 {
                        log("  [t=\(step)] price=\(absolutePrice) yt=\(ytPrice) HF=\(hf) collateral=\(btcCollateralValue) debt=\(debt)")
                    }

                    if hf < 1.0 {
                        liquidationCount = liquidationCount + 1
                        log("  *** LIQUIDATION agent=\(a) at t=\(step)! HF=\(hf) ***")
                    }
                }
                a = a + 1
            }

            previousBTCPrice = absolutePrice
        }

        step = step + 1
    }

    // Final state from agent 0
    let finalBTCCollateral = getBTCCollateralFromPosition(pid: pids[0])
    let finalDebt = getMOETDebtFromPosition(pid: pids[0])
    let finalHF = (finalBTCCollateral * previousBTCPrice) / finalDebt
    let finalPrice = prices[prices.length - 1]

    log("\n=== SIMULATION RESULTS ===")
    log("Agents:              \(config.numAgents)")
    log("Rebalance events:    \(rebalanceCount)")
    log("Liquidation count:   \(liquidationCount)")
    log("Lowest price:        \(lowestPrice)")
    log("Lowest HF observed:  \(lowestHF)")
    log("Final price:         \(finalPrice)")
    log("Final HF (agent 0):  \(finalHF)")
    log("===========================\n")

    return SimResult(
        rebalanceCount: rebalanceCount,
        liquidationCount: liquidationCount,
        lowestHF: lowestHF,
        finalHF: finalHF,
        lowestPrice: lowestPrice,
        finalPrice: finalPrice
    )
}

// ============================================================================
// TEST
// ============================================================================

access(all)
fun test_FlashCrashModerate_ZeroLiquidations() {
    let result = runSimulation(config: SimConfig(
        prices: flash_crash_moderate_prices,
        tickIntervalSeconds: 5.0,
        numAgents: 5,
        fundingPerAgent: 1.0,
        yieldAPR: flash_crash_moderate_constants.yieldAPR,
        expectedLiquidationCount: 0,
        poolResetInterval: 43200.0,  // ALM arb every 12h (43200 seconds)
        initialHF: 1.15,
        rebalancingHF: 1.05,
        targetHF: 1.08
    ))

    Test.assertEqual(0, result.liquidationCount)
    Test.assert(result.finalHF > 1.0, message: "Expected final HF > 1.0 but got \(result.finalHF)")
    Test.assert(result.lowestHF > 1.0, message: "Expected lowest HF > 1.0 but got \(result.lowestHF)")

    log("=== TEST PASSED: Zero liquidations under flash crash ===")
}
