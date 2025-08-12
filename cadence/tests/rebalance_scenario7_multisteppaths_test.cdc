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
fun test_RebalanceTideScenario7_MultiStepPaths_Bear() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.00000000, 0.90000000, 0.80000000, 0.70000000, 0.60000000, 0.50000000, 0.40000000, 0.30000000]
    let yieldPrices = [1.00000000, 1.10000000, 1.20000000, 1.30000000, 1.40000000, 1.50000000, 1.60000000, 1.70000000]
    let expectedDebts = [615.38461539, 591.71597633, 559.07274842, 517.85905222, 468.39322560, 410.91640121, 345.59122973, 272.48539268]
    let expectedYieldUnits = [615.38461539, 537.92361485, 465.89395702, 398.35311710, 334.56658971, 273.94426747, 215.99451858, 160.28552510]
    let expectedCollaterals = [1000.00000000, 961.53846154, 908.49321619, 841.52095986, 761.13899159, 667.73915197, 561.58574832, 442.78876310]
    let actions: [String] = ["none", "Bal sell 55.944055944 | Repay 23.668639053", "Bal sell 44.826967904 | Repay 32.643227910", "Bal sell 35.837996693 | Repay 41.213696198", "Bal sell 28.453794079 | Repay 49.465826628", "Bal sell 22.304439314 | Repay 57.476824387", "Bal sell 17.121516716 | Repay 65.325171475", "Bal sell 12.705559917 | Repay 73.105837059"]

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

    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("Scenario7_MultiStepPaths_Bear", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001), message: "Debt mismatch at step 0")
    Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001), message: "Yield mismatch at step 0")
    Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001), message: "Collateral mismatch at step 0")

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

        logStep("Scenario7_MultiStepPaths_Bear", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001), message: "Debt mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001), message: "Yield mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001), message: "Collateral mismatch at step \(i)")
        i = i + 1
    }

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
}



access(all)
fun test_RebalanceTideScenario7_MultiStepPaths_Bull() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.00000000, 1.20000000, 1.50000000, 2.00000000, 2.50000000, 3.00000000, 3.50000000, 4.00000000]
    let yieldPrices = [1.00000000, 1.00000000, 1.05000000, 1.05000000, 1.10000000, 1.10000000, 1.15000000, 1.20000000]
    let expectedDebts = [615.38461539, 738.46153846, 923.07692308, 1230.76923077, 1598.33192449, 1917.99830938, 2237.66469428, 2673.18463065]
    let expectedYieldUnits = [615.38461539, 738.46153846, 914.28571429, 1207.32600733, 1453.02902226, 1743.63482671, 2021.60559619, 2227.65385888]
    let expectedCollaterals = [1000.00000000, 1200.00000000, 1500.00000000, 2000.00000000, 2597.28937729, 3116.74725275, 3636.20512821, 4343.92502481]
    let actions: [String] = ["none", "Borrow 123.076923077", "Borrow 184.615384615", "Borrow 307.692307692", "Bal sell 88.444888445 | Borrow 367.562693717", "Borrow 319.666384897", "Borrow 319.666384898", "Bal sell 156.885017622 | Borrow 435.519936373"]

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

    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("Scenario7_MultiStepPaths_Bull", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001), message: "Debt mismatch at step 0")
    Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001), message: "Yield mismatch at step 0")
    Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001), message: "Collateral mismatch at step 0")

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

        logStep("Scenario7_MultiStepPaths_Bull", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001), message: "Debt mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001), message: "Yield mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001), message: "Collateral mismatch at step \(i)")
        i = i + 1
    }

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
}



access(all)
fun test_RebalanceTideScenario7_MultiStepPaths_Sideways() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.00000000, 1.10000000, 0.90000000, 1.05000000, 0.95000000, 1.02000000, 0.98000000, 1.00000000]
    let yieldPrices = [1.00000000, 1.05000000, 1.05000000, 1.10000000, 1.10000000, 1.15000000, 1.15000000, 1.20000000]
    let expectedDebts = [615.38461539, 676.92307692, 553.84615385, 682.22034376, 617.24697769, 662.72833394, 636.73898751, 684.78648552]
    let expectedYieldUnits = [615.38461539, 673.99267399, 556.77655678, 620.20031251, 561.13361608, 600.68262152, 578.08318984, 570.65540460]
    let expectedCollaterals = [1000.00000000, 1100.00000000, 900.00000000, 1108.60805861, 1003.02633874, 1076.93354265, 1034.70085470, 1112.77803897]
    let actions: [String] = ["none", "Borrow 61.538461538", "Repay 123.076923077", "Bal sell 53.280053281 | Borrow 128.374189913", "Repay 64.973366072", "Borrow 45.481356251", "Repay 25.989346429", "Bal sell 47.467366914 | Borrow 48.047498012"]

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

    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("Scenario7_MultiStepPaths_Sideways", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001), message: "Debt mismatch at step 0")
    Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001), message: "Yield mismatch at step 0")
    Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001), message: "Collateral mismatch at step 0")

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

        logStep("Scenario7_MultiStepPaths_Sideways", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001), message: "Debt mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001), message: "Yield mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001), message: "Collateral mismatch at step \(i)")
        i = i + 1
    }

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
}



access(all)
fun test_RebalanceTideScenario7_MultiStepPaths_Crisis() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.00000000, 0.50000000, 0.20000000, 0.10000000, 0.15000000, 0.30000000, 0.70000000, 1.20000000]
    let yieldPrices = [1.00000000, 2.00000000, 5.00000000, 10.00000000, 10.00000000, 10.00000000, 10.00000000, 10.00000000]
    let expectedDebts = [615.38461539, 686.39053255, 908.14747383, 1012.93372081, 1519.40058121, 3038.80116241, 7090.53604563, 12155.20464966]
    let expectedYieldUnits = [615.38461539, 343.19526627, 181.62949477, 101.29337208, 151.94005812, 303.88011624, 709.05360456, 1215.52046497]
    let expectedCollaterals = [1000.00000000, 1115.38461539, 1475.73964497, 1646.01729631, 2469.02594446, 4938.05188892, 11522.12107415, 19752.20755569]
    let actions: [String] = ["none", "Bal sell 307.692307693 | Borrow 71.005917160", "Bal sell 205.917159763 | Borrow 221.756941282", "Bal sell 90.814747382 | Borrow 104.786246978", "Borrow 506.466860402", "Borrow 1519.400581207", "Borrow 4051.734883219", "Borrow 5064.668604022"]

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

    var actualDebt = getMOETDebtFromPosition(pid: pid)
    var actualYieldUnits = getAutoBalancerBalance(id: tideIDs![0]) ?? 0.0
    var flowCollateralAmount0 = getFlowCollateralFromPosition(pid: pid)
    var actualCollateral = flowCollateralAmount0 * flowPrices[0]

    logStep("Scenario7_MultiStepPaths_Crisis", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
    Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[0], tolerance: 0.0000001), message: "Debt mismatch at step 0")
    Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[0], tolerance: 0.0000001), message: "Yield mismatch at step 0")
    Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[0], tolerance: 0.0000001), message: "Collateral mismatch at step 0")

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

        logStep("Scenario7_MultiStepPaths_Crisis", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
        Test.assert(equalAmounts(a: actualDebt, b: expectedDebts[i], tolerance: 0.0000001), message: "Debt mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualYieldUnits, b: expectedYieldUnits[i], tolerance: 0.0000001), message: "Yield mismatch at step \(i)")
        Test.assert(equalAmounts(a: actualCollateral, b: expectedCollaterals[i], tolerance: 0.0000001), message: "Collateral mismatch at step \(i)")
        i = i + 1
    }

    closeTide(signer: user, id: tideIDs![0], beFailed: false)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert((flowBalanceAfter - flowBalanceBefore) > 0.1, message: "Expected user's Flow balance > 0 after test")
}
