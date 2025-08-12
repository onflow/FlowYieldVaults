import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "TidalYieldStrategies"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let tidalYieldAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@TidalYieldStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let targetHealthFactor = 1.3

access(all) var snapshot: UInt64 = 0

// Inline helper for generated tests
access(all) fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            if balance.direction.rawValue == 1 {  // Debit = 1
                return balance.balance
            }
        }
    }
    return 0.0
}

// Inline helper for generated tests (align with legacy tests)
access(all) fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for balance in positionDetails.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            // Credit means collateral deposit
            if balance.direction.rawValue == 0 {  // Credit = 0
                return balance.balance
            }
        }
    }
    return 0.0
}

// Debug helper to log per-step comparisons (machine-parsable)
access(all) fun logStep(_ label: String, _ i: Int, _ actualDebt: UFix64, _ expectedDebt: UFix64, _ actualY: UFix64, _ expectedY: UFix64, _ actualColl: UFix64, _ expectedColl: UFix64) {
    log("DRIFT|\(label)|\(i)|\(actualDebt)|\(expectedDebt)|\(actualY)|\(expectedY)|\(actualColl)|\(expectedColl)")
}

access(all)
fun setup() {
	deployContracts()

	// set mocked token prices
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
	setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

	// mint tokens & set liquidity in mock swapper contract
	let reserveAmount = 100_000_00.0
	setupMoetVault(protocolAccount, beFailed: false)
	setupYieldVault(protocolAccount, beFailed: false)
	mintFlow(to: protocolAccount, amount: reserveAmount)
	mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
	setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

	// setup TidalProtocol with a Pool & add FLOW as supported token
	createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
	addSupportedTokenSimpleInterestCurve(
		signer: protocolAccount,
		tokenTypeIdentifier: flowTokenIdentifier,
		collateralFactor: 0.8,
		borrowFactor: 1.0,
		depositRate: 1_000_000.0,
		depositCapacityCap: 1_000_000.0
	)

	// open wrapped position (pushToDrawDownSink)
	// the equivalent of depositing reserves
	let openRes = executeTransaction(
		"../transactions/mocks/position/create_wrapped_position.cdc",
		[reserveAmount/2.0, /storage/flowTokenVault, true],
		protocolAccount
	)
	Test.expect(openRes, Test.beSucceeded())

	// enable mocked Strategy creation
	addStrategyComposer(
		signer: tidalYieldAccount,
		strategyIdentifier: strategyIdentifier,
		composerIdentifier: Type<@TidalYieldStrategies.TracerStrategyComposer>().identifier,
		issuerStoragePath: TidalYieldStrategies.IssuerStoragePath,
		beFailed: false
	)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_RebalanceTideScenario9_ExtremeShocks_FlashCrash() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.00000000, 0.30000000]
    let yieldPrices = [1.00000000, 1.00000000]
    let expectedDebts = [615.38461539, 184.61538462]
    let expectedYieldUnits = [615.38461539, 184.61538462]
    let expectedCollaterals = [1000.00000000, 300.00000000]
    let actions: [String] = ["none", "Repay 430.769230770"]

    // Keep initial prices at 1.0/1.0 for opening the Tide to match baseline CSV state

    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    mintFlow(to: user, amount: fundingAmount)
    createTide(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: fundingAmount,
        beFailed: false
    )

    var tideIDs = getTideIDs(address: user.address)
    var pid  = 1 as UInt64
    Test.assert(tideIDs != nil, message: "Expected user's Tide IDs to be non-nil but encountered nil")
    Test.assertEqual(1, tideIDs!.length)

    // Initial stabilization
    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)

    // Step 0: set prices to step-0, execute CSV actions (if provided) in-order, then assert
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[0])
    setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[0])
    if true {
        let a0 = actions[0]
        if a0 != "none" {
            let parts0 = a0.split(separator: "|")
            var j0: Int = 0
            while j0 < parts0.length {
                let p0 = parts0[j0]
                if p0.contains("Bal") {
                    rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                } else if p0.contains("Borrow") || p0.contains("Repay") {
                    rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
                }
                j0 = j0 + 1
            }
        }
    }

    var allGood: Bool = true
    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("Scenario9_ExtremeShocks_FlashCrash", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    let okDebt0 = equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001)
    let okY0 = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001)
    let okC0 = equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001)
    if !(okDebt0 && okY0 && okC0) { allGood = false }

    // Subsequent steps: set prices, rebalance, assert
    var i = 1
    while i < flowPrices.length {
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: flowTokenIdentifier, price: flowPrices[i])
        setMockOraclePrice(signer: tidalYieldAccount, forTokenIdentifier: yieldTokenIdentifier, price: yieldPrices[i])

        // Execute rebalances per CSV 'Actions' for this step in-order if available; otherwise do both
        if true {
            let a = actions[i]
            if a != "none" {
                let parts = a.split(separator: "|")
                var idx: Int = 0
                while idx < parts.length {
                    let p = parts[idx]
                    if p.contains("Bal") {
                        rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                    } else if p.contains("Borrow") || p.contains("Repay") {
                        rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
                    }
                    idx = idx + 1
                }
            } else {
                rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
                rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
            }
        } else {
            rebalanceTide(signer: tidalYieldAccount, id: tideIDs![0], force: true, beFailed: false)
            rebalancePosition(signer: protocolAccount, pid: pid, force: true, beFailed: false)
        }

        actualDebt = getMOETDebtFromPosition(pid: pid)
        actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
        let flowCollateralAmount = getFlowCollateralFromPosition(pid: pid)
        actualCollateral = flowCollateralAmount * flowPrices[i]

        logStep("Scenario9_ExtremeShocks_FlashCrash", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        let okDebt = equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001)
        let okY = equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001)
        let okC = equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001)
        if !(okDebt && okY && okC) { allGood = false }
        i = i + 1
    }

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
    Test.assert(allGood, message: "One or more steps exceeded tolerance")
}
