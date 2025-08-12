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
fun test_RebalanceTideScenario8_RandomWalks_Walk0() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.05577072, 0.96076374, 1.05164092, 1.21661376, 1.17861736, 1.04597009, 0.84787841, 0.89871192, 0.79821458, 0.89701134]
    let yieldPrices = [1.00375161, 1.03735883, 1.14265586, 1.15755704, 1.16273084, 1.25086966, 1.28817766, 1.39347488, 1.51664391, 1.51812236]
    let expectedDebts = [649.70505785, 591.23922215, 700.45785445, 810.33995785, 785.03201031, 741.77325059, 601.29206912, 682.31573575, 643.13034594, 722.73199276]
    let expectedYieldUnits = [649.57678207, 593.21650077, 613.00858564, 707.93445089, 686.16849544, 593.00602910, 483.95183111, 489.65054770, 424.04834781, 476.48262380]
    let expectedCollaterals = [1055.77071900, 960.76373600, 1138.24401348, 1316.80243151, 1275.67701675, 1205.38153220, 977.09961233, 1108.76307060, 1045.08681216, 1174.43948823]
    let actions: [String] = ["Borrow 34.320442461", "Repay 58.465835692", "Bal sell 75.791052480 | Borrow 109.218632295", "Borrow 109.882103405", "Repay 25.307947548", "Bal sell 58.579518922 | Repay 43.258759720", "Repay 140.481181463", "Bal sell 52.446333661 | Borrow 81.023666631", "Bal sell 39.765291542 | Repay 39.185389811", "Borrow 79.601646816"]

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

    logStep("Scenario8_RandomWalks_Walk0", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
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

        logStep("Scenario8_RandomWalks_Walk0", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
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



access(all)
fun test_RebalanceTideScenario8_RandomWalks_Walk1() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.12232770, 1.05061119, 1.24275246, 1.04030602, 1.18490621, 1.33047349, 1.34975370, 1.28417423, 1.45337942, 1.66365837]
    let yieldPrices = [1.10472091, 1.13048513, 1.18756240, 1.20479091, 1.31389545, 1.45771414, 1.67049283, 1.80881982, 1.97663844, 2.14782091]
    let expectedDebts = [730.32082296, 683.65347340, 840.93562465, 703.94581332, 849.21005048, 1010.73928442, 1116.17688482, 1118.82372856, 1330.12029881, 1593.45326523]
    let expectedYieldUnits = [661.09079407, 619.80997715, 708.11910809, 594.41488718, 646.33000277, 693.37276445, 668.17220769, 618.53796324, 672.92038437, 741.89298560]
    let expectedCollaterals = [1186.77133731, 1110.93689427, 1366.52039006, 1143.91194665, 1379.96633203, 1642.45133717, 1813.78743783, 1818.08855891, 2161.44548557, 2589.36155600]
    let actions: [String] = ["Bal sell 58.334766530 | Borrow 114.936207574", "Repay 46.667349560", "Bal sell 44.132037448 | Borrow 157.282151255", "Repay 136.989811330", "Bal sell 58.644850991 | Borrow 145.264237156", "Bal sell 63.767190202 | Borrow 161.529233935", "Bal sell 88.318217765 | Borrow 105.437600402", "Bal sell 51.097543177 | Borrow 2.646843745", "Bal sell 52.514503447 | Borrow 211.296570249", "Bal sell 53.632112024 | Borrow 263.332966417"]

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

    logStep("Scenario8_RandomWalks_Walk1", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
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

        logStep("Scenario8_RandomWalks_Walk1", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
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



access(all)
fun test_RebalanceTideScenario8_RandomWalks_Walk2() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.08182873, 0.96408175, 0.80203579, 0.67403134, 0.71061357, 0.67371310, 0.61091706, 0.64709200, 0.56197058, 0.48630742]
    let yieldPrices = [1.00687366, 1.05058023, 1.08726505, 1.13259970, 1.19458102, 1.23212199, 1.40523290, 1.53362854, 1.70135998, 1.79819853]
    let expectedDebts = [665.74075939, 613.78086784, 510.61460991, 455.96182071, 496.06393361, 470.30451785, 478.07198754, 533.26139768, 499.00440347, 449.29740436]
    let expectedYieldUnits = [665.39699142, 584.23036399, 489.34433981, 402.57985334, 415.26185741, 394.35531083, 340.20836610, 347.71222986, 293.29736691, 249.85973287]
    let expectedCollaterals = [1081.82873400, 997.39391024, 829.74874111, 740.93795866, 806.10389211, 764.24484151, 776.86697976, 866.54977123, 810.88215564, 730.10828208]
    let actions: [String] = ["Borrow 50.356144000", "Bal sell 31.708346885 | Repay 51.959891547", "Repay 103.166257926", "Bal sell 38.510200998 | Repay 54.652789200", "Bal sell 20.888019382 | Borrow 40.102112896", "Repay 25.759415758", "Bal sell 59.674476649 | Borrow 7.767469693", "Bal sell 28.482301655 | Borrow 55.189410138", "Bal sell 34.279797748 | Repay 34.256994211", "Bal sell 15.794969289 | Repay 49.706999111"]

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

    logStep("Scenario8_RandomWalks_Walk2", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
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

        logStep("Scenario8_RandomWalks_Walk2", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
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



access(all)
fun test_RebalanceTideScenario8_RandomWalks_Walk3() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.19580934, 1.22304975, 1.39077974, 1.24004596, 1.14850728, 1.01573195, 1.16864740, 1.24130860, 1.44714120, 1.31104056]
    let yieldPrices = [1.09599996, 1.20855054, 1.34922581, 1.35572238, 1.41016973, 1.60961914, 1.68559587, 1.78562719, 1.90852795, 1.97913227]
    let expectedDebts = [772.23768672, 838.63086730, 1013.71311602, 903.84610707, 837.12528918, 842.27325718, 969.07501207, 1090.63577459, 1317.67843127, 1193.75349767]
    let expectedYieldUnits = [704.59645263, 693.91460056, 751.32947243, 670.29001302, 622.97597939, 523.27487778, 598.50154231, 610.78582297, 690.41610563, 627.80031408]
    let expectedCollaterals = [1254.88624092, 1362.77515937, 1647.28381353, 1468.74992398, 1360.32859492, 1368.69404291, 1574.74689462, 1772.28313372, 2141.22745081, 1939.84943372]
    let actions: [String] = ["Bal sell 53.902283635 | Borrow 156.853071337", "Bal sell 65.618057237 | Borrow 66.393180580", "Bal sell 72.350099580 | Borrow 175.082248714", "Repay 109.867008950", "Repay 66.720817886", "Bal sell 102.899353846 | Borrow 5.147967997", "Borrow 126.801754896", "Bal sell 55.793066610 | Borrow 121.560762521", "Bal sell 39.331903497 | Borrow 227.042656672", "Repay 123.924933594"]

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

    logStep("Scenario8_RandomWalks_Walk3", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
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

        logStep("Scenario8_RandomWalks_Walk3", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
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



access(all)
fun test_RebalanceTideScenario8_RandomWalks_Walk4() {
    let fundingAmount = 1000.0
    let user = Test.createAccount()

    let flowPrices = [1.02454725, 1.05921219, 1.01658971, 1.21890635, 1.01944911, 0.86027197, 0.96077904, 0.79303767, 0.95041485, 1.12950280]
    let yieldPrices = [1.03941124, 1.17939232, 1.21819210, 1.31129724, 1.32056478, 1.44485225, 1.53634606, 1.62429096, 1.75320630, 1.97957496]
    let expectedDebts = [630.49061785, 721.01036534, 691.99705364, 877.97418187, 734.30579239, 666.35849694, 770.17738944, 662.84352618, 826.75801949, 1048.23652164]
    let expectedYieldUnits = [629.91784522, 611.34056285, 587.52386628, 669.54627455, 560.75313385, 461.19490649, 501.30462660, 408.08176868, 471.56915765, 529.52605546]
    let expectedCollaterals = [1024.54725400, 1171.64184367, 1124.49521216, 1426.70804553, 1193.24691263, 1082.83255753, 1251.53825785, 1077.12073004, 1343.48178167, 1703.38434766]
    let actions: [String] = ["Borrow 15.106002461", "Bal sell 95.328458281 | Borrow 90.519747489", "Repay 29.013311698", "Bal sell 59.804419821 | Borrow 185.977128230", "Repay 143.668389479", "Bal sell 52.531068988 | Repay 67.947295444", "Bal sell 27.465479901 | Borrow 103.818892500", "Bal sell 27.142416563 | Repay 107.333863264", "Bal sell 30.006738353 | Borrow 163.914493306", "Bal sell 53.924948693 | Borrow 221.478502153"]

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

    logStep("Scenario8_RandomWalks_Walk4", 0, actualDebt, expectedDebts[0], actualYieldUnits, expectedYieldUnits[0], actualCollateral, expectedCollaterals[0])
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

        logStep("Scenario8_RandomWalks_Walk4", i, actualDebt, expectedDebts[i], actualYieldUnits, expectedYieldUnits[i], actualCollateral, expectedCollaterals[i])
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
