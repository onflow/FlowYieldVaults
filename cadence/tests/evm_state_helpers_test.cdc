// Tests that EVM state helpers correctly set Uniswap V3 pool price and ERC4626 vault price
#test_fork(network: "mainnet-fork", height: 143292255)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowToken"

access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)

access(all) let factoryAddress = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"
access(all) let routerAddress = "0xeEDC6Ff75e1b10B903D9013c358e446a73d35341"
access(all) let quoterAddress = "0x370A8DF17742867a44e56223EC20D82092242C85"

access(all) let morphoVaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
access(all) let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
access(all) let wflowAddress = "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

access(all) let pyusd0BalanceSlot = 1 as UInt256
access(all) let fusdevBalanceSlot = 12 as UInt256
access(all) let wflowBalanceSlot = 3 as UInt256
access(all) let morphoVaultTotalSupplySlot = 11 as UInt256
access(all) let morphoVaultTotalAssetsSlot = 15 as UInt256

access(all) let pyusd0VaultTypeId = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"

// Vault public paths
access(all) let pyusd0PublicPath = /public/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault
access(all) let fusdevPublicPath = /public/EVMVMBridgedToken_d069d989e2f44b70c65347d1853c0c67e10a9f8dVault
access(all) let wflowPublicPath = /public/EVMVMBridgedToken_d3bf53dac106a0290b0483ecbc89d40fcc961f3eVault

access(all) let univ3PoolFee: UInt64 = 3000

// Fee tiers for testing (in basis points / 100 = percentage)
// 100 = 0.01%, 500 = 0.05%, 3000 = 0.3%
access(all) let feeTier100: UInt64 = 100
access(all) let feeTier500: UInt64 = 500
access(all) let feeTier3000: UInt64 = 3000

access(all) var snapshot: UInt64 = 0
access(all) var testAccount = Test.createAccount()

access(all)
fun setup() {
    deployContractsForFork()
    transferFlow(signer: whaleFlowAccount, recipient: testAccount.address, amount: 10000000.0)
    createCOA(testAccount, fundingAmount: 5.0)
    
    // Set up a WFLOW/PYUSD0 pool at 1:1 so we can swap FLOW→PYUSD0 to fund the Cadence vault
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: pyusd0Address,
        fee: univ3PoolFee,
        priceTokenBPerTokenA: 1.0,
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: testAccount
    )

    // Swap FLOW→PYUSD0 to create the Cadence-side PYUSD0 vault (needed for ERC4626 deposit test)
    let swapRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/execute_univ3_swap.cdc"),
            authorizers: [testAccount.address],
            signers: [testAccount],
            arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, 11000.0]
        )
    )
    Test.expect(swapRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
    Test.commitBlock()
}

access(all)
fun test_UniswapV3PriceSetAndSwap() {
    let prices = [0.5, 1.0, 2.0, 3.0, 5.0]
    let flowAmount = 10000.0

    for price in prices {
        Test.reset(to: snapshot)

        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: UFix128(price),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!

        let swapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, flowAmount]
            )
        )
        Test.expect(swapRes, Test.beSucceeded())

        let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!
        let swapOutput = balanceAfter - balanceBefore
        let expectedOut = feeAdjustedPrice(UFix128(price), fee: univ3PoolFee, reverse: true) * UFix128(flowAmount)

        // PYUSD0 has 6 decimals, so we need to use a tolerance of 1e-6
        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: UFix64(swapOutput), b: UFix64(expectedOut), tolerance: tolerance),
            message: "Pool price \(price): swap output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
        )
        log("Pool price \(price): expected=\(expectedOut) actual=\(swapOutput)")
    }
}

access(all)
fun test_ERC4626PriceSetAndDeposit() {
    let multipliers = [0.5, 1.0, 2.0, 3.0, 5.0]
    let amountIn = 10000.0

    for multiplier in multipliers {
        Test.reset(to: snapshot)

        setVaultSharePrice(
            vaultAddress: morphoVaultAddress,
            assetAddress: pyusd0Address,
            assetBalanceSlot: pyusd0BalanceSlot,
            totalSupplySlot: morphoVaultTotalSupplySlot,
            vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
            priceMultiplier: multiplier,
            signer: testAccount
        )

        let depositRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_morpho_deposit.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [pyusd0VaultTypeId, morphoVaultAddress, amountIn]
            )
        )
        Test.expect(depositRes, Test.beSucceeded())

        let fusdevBalance = getBalance(address: testAccount.address, vaultPublicPath: fusdevPublicPath)!
        let expectedShares = amountIn / multiplier

        // FUSDEV has 18 decimals, so we need to use a tolerance of 1e-8 (Cadence UFix64 precision)
        let tolerance: UFix64 = 0.00000001
        Test.assert(
            equalAmounts(a: fusdevBalance, b: expectedShares, tolerance: tolerance),
            message: "Multiplier \(multiplier): FUSDEV shares \(fusdevBalance) not within \(tolerance) of expected \(expectedShares)"
        )
        log("Multiplier \(multiplier): expected=\(expectedShares) actual=\(fusdevBalance)")
    }
}

// =============================================================================
// Fee-Adjusted Price Tests
// These tests verify the actual usage patterns in forked_rebalance_*_test.cdc
// =============================================================================

/// Test forward fee-adjusted price: pre-adjust pool price so swap output equals exact target
/// Pattern: setPoolToPrice(priceTokenBPerTokenA: feeAdjustedPrice(targetPrice, fee, reverse: false))
/// When swapping A→B, the output should equal targetPrice × amountIn exactly (not fee-reduced)
access(all)
fun test_UniswapV3ForwardFeeAdjustedPrice() {
    let targetPrices = [0.5, 1.0, 2.0, 3.0, 5.0]
    let flowAmount = 10000.0

    for targetPrice in targetPrices {
        Test.reset(to: snapshot)

        // Pre-adjust price: set pool price = targetPrice / (1 - fee)
        // So when swapping, output = poolPrice × (1 - fee) = targetPrice
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(targetPrice), fee: univ3PoolFee, reverse: false),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!

        // Swap WFLOW → PYUSD0 (forward direction)
        let swapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, flowAmount]
            )
        )
        Test.expect(swapRes, Test.beSucceeded())

        let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!
        let swapOutput = balanceAfter - balanceBefore
        // Expected output should be exactly targetPrice × flowAmount (no fee reduction)
        let expectedOut = UFix128(targetPrice) * UFix128(flowAmount)

        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: UFix64(swapOutput), b: UFix64(expectedOut), tolerance: tolerance),
            message: "Forward fee-adjusted price \(targetPrice): swap output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
        )
        log("Forward fee-adjusted price \(targetPrice): expected=\(expectedOut) actual=\(swapOutput)")
    }
}

/// Test reverse fee-adjusted price: pre-adjust pool price for reverse swap direction
/// Pattern: setPoolToPrice(priceTokenBPerTokenA: feeAdjustedPrice(targetPrice, fee, reverse: true))
/// When swapping B→A (reverse direction), the output should equal amountIn / targetPrice exactly
access(all)
fun test_UniswapV3ReverseFeeAdjustedPrice() {
    let targetPrices = [0.5, 1.0, 2.0, 3.0, 5.0]
    let pyusdAmount = 10000.0

    for targetPrice in targetPrices {
        Test.reset(to: snapshot)

        // Pre-adjust price with reverse=true for B→A swap direction
        // For reverse swaps, we deflate the price: poolPrice = targetPrice × (1 - fee)
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(targetPrice), fee: univ3PoolFee, reverse: true),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath) ?? 0.0

        // Swap PYUSD0 → WFLOW (reverse direction relative to pool's A→B)
        let swapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, pyusd0Address, wflowAddress, univ3PoolFee, pyusdAmount]
            )
        )
        Test.expect(swapRes, Test.beSucceeded())

        let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath)!
        let swapOutput = balanceAfter - balanceBefore
        // For reverse swap: PYUSD0 → WFLOW, output = amountIn / priceTokenBPerTokenA
        // With reverse fee adjustment, output should be pyusdAmount / targetPrice
        let expectedOut = UFix128(pyusdAmount) / UFix128(targetPrice)

        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: UFix64(swapOutput), b: UFix64(expectedOut), tolerance: tolerance),
            message: "Reverse fee-adjusted price \(targetPrice): swap output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
        )
        log("Reverse fee-adjusted price \(targetPrice): expected=\(expectedOut) actual=\(swapOutput)")
    }
}

/// Test round-trip swap: swap forward then backward without resetting pool price
/// Verifies that after a round-trip, the balance reflects fees paid twice
/// Round-trip: WFLOW → PYUSD0 → WFLOW
/// Expected final amount ≈ original × (1 - fee)² (fees deducted on each swap)
access(all)
fun test_UniswapV3RoundTripSwap() {
    let prices = [0.5, 1.0, 2.0, 3.0, 5.0]
    let initialAmount = 5000.0

    for price in prices {
        Test.reset(to: snapshot)

        // Set pool price once (no fee adjustment - we want to observe natural fee behavior)
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: UFix128(price),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        // Record initial WFLOW balance (from FlowToken, not bridged WFLOW)
        let wflowBalanceInitial = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath) ?? 0.0
        let pyusdBalanceInitial = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!

        // === Step 1: Swap WFLOW → PYUSD0 ===
        let forwardSwapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, initialAmount]
            )
        )
        Test.expect(forwardSwapRes, Test.beSucceeded())

        let pyusdBalanceAfterForward = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!
        let pyusdReceived = pyusdBalanceAfterForward - pyusdBalanceInitial

        // Forward swap output should be: initialAmount × price × (1 - fee)
        let expectedPyusdReceived = UFix128(initialAmount) * UFix128(price) * (1.0 - UFix128(univ3PoolFee) / 1_000_000.0)
        log("Round-trip price=\(price) Step 1: WFLOW→PYUSD0: sent=\(initialAmount) received=\(pyusdReceived) expected=\(expectedPyusdReceived)")

        // === Step 2: Swap all PYUSD0 back → WFLOW ===
        let reverseSwapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, pyusd0Address, wflowAddress, univ3PoolFee, pyusdReceived]
            )
        )
        Test.expect(reverseSwapRes, Test.beSucceeded())

        let wflowBalanceFinal = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath)!
        let wflowReturned = wflowBalanceFinal - wflowBalanceInitial

        // Round-trip: started with initialAmount WFLOW, should get back approximately:
        // initialAmount × (1 - fee)² (lost fee on each leg)
        // Note: The actual calculation is more complex due to price conversion:
        // Forward: WFLOW → PYUSD0 = amount × price × (1 - fee)
        // Reverse: PYUSD0 → WFLOW = pyusd / price × (1 - fee)
        // Net: amount × (1 - fee)²
        let feeMultiplier = 1.0 - (UFix64(univ3PoolFee) / 1_000_000.0)
        let expectedWflowReturned = initialAmount * feeMultiplier * feeMultiplier

        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: wflowReturned, b: expectedWflowReturned, tolerance: tolerance),
            message: "Round-trip price=\(price): returned \(wflowReturned) not within \(tolerance) of expected \(expectedWflowReturned)"
        )

        let feesLost = initialAmount - wflowReturned
        let feePercentage = (feesLost / initialAmount) * 100.0
        log("Round-trip price=\(price) Step 2: PYUSD0→WFLOW: sent=\(pyusdReceived) returned=\(wflowReturned) expected=\(expectedWflowReturned)")
        log("Round-trip price=\(price) Summary: initial=\(initialAmount) final=\(wflowReturned) fees_lost=\(feesLost) (\(feePercentage)%)")
    }
}

/// Test different fee tiers: verify fee adjustment works correctly across 100, 500, 3000 bps
/// This matches the actual fee tiers used in production (100 for stablecoin pairs, 3000 for volatile)
access(all)
fun test_UniswapV3DifferentFeeTiers() {
    let feeTiers: [UInt64] = [feeTier100, feeTier500, feeTier3000]
    let targetPrice = 1.5
    let amount = 10000.0

    for fee in feeTiers {
        Test.reset(to: snapshot)

        // Set pool with forward fee adjustment for each fee tier
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: fee,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(targetPrice), fee: fee, reverse: false),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!

        let swapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, fee, amount]
            )
        )
        Test.expect(swapRes, Test.beSucceeded())

        let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!
        let swapOutput = balanceAfter - balanceBefore
        let expectedOut = targetPrice * amount

        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: swapOutput, b: expectedOut, tolerance: tolerance),
            message: "Fee tier \(fee): swap output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
        )
        log("Fee tier \(fee) bps: expected=\(expectedOut) actual=\(swapOutput)")
    }
}

/// Test inverted price with fee adjustment
/// Pattern: priceTokenBPerTokenA: feeAdjustedPrice(1.0 / UFix128(price), fee, reverse: true)
/// Used when token ordering differs from the natural price direction
access(all)
fun test_UniswapV3InvertedPriceWithFeeAdjustment() {
    let prices = [0.5, 1.0, 2.0, 3.0, 5.0]
    let amount = 10000.0

    for price in prices {
        Test.reset(to: snapshot)

        // Inverted price pattern: 1.0 / price
        // This is used when we want to express price in the opposite direction
        // e.g., if price = 2.0 (1 WFLOW = 2 PYUSD0), inverted = 0.5 (1 PYUSD0 = 0.5 WFLOW)
        let invertedPrice = 1.0 / price

        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(invertedPrice), fee: univ3PoolFee, reverse: true),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        // Swap PYUSD0 → WFLOW
        let wflowBalanceBefore = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath) ?? 0.0

        let swapRes = Test.executeTransaction(
            Test.Transaction(
                code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                authorizers: [testAccount.address],
                signers: [testAccount],
                arguments: [factoryAddress, routerAddress, quoterAddress, pyusd0Address, wflowAddress, univ3PoolFee, amount]
            )
        )
        Test.expect(swapRes, Test.beSucceeded())

        let wflowBalanceAfter = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath)!
        let swapOutput = wflowBalanceAfter - wflowBalanceBefore
        // With inverted price = 1/price, output = amount / invertedPrice = amount × price
        let expectedOut = amount * price

        let tolerance = 0.000001
        Test.assert(
            equalAmounts(a: swapOutput, b: expectedOut, tolerance: tolerance),
            message: "Inverted price (1/\(price)): swap output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
        )
        log("Inverted price (1/\(price) = \(invertedPrice)): expected=\(expectedOut) actual=\(swapOutput)")
    }
}

/// Test dynamic fee direction based on condition (as used in rebalance tests)
/// Pattern: priceTokenBPerTokenA: feeAdjustedPrice(1.0, fee, reverse: price < 1.0)
/// Direction changes based on whether we're in surplus or deficit scenario
access(all)
fun test_UniswapV3DynamicFeeDirection() {
    // Prices that trigger different directions
    // price < 1.0: reverse=true (deficit scenario)
    // price >= 1.0: reverse=false (surplus scenario)
    let prices = [0.5, 0.8, 1.0, 1.2, 2.0]
    let amount = 5000.0

    for price in prices {
        Test.reset(to: snapshot)

        let isDeficit = price < 1.0

        // Set pool with dynamic direction based on price
        setPoolToPrice(
            factoryAddress: factoryAddress,
            tokenAAddress: wflowAddress,
            tokenBAddress: pyusd0Address,
            fee: univ3PoolFee,
            priceTokenBPerTokenA: feeAdjustedPrice(UFix128(price), fee: univ3PoolFee, reverse: isDeficit),
            tokenABalanceSlot: wflowBalanceSlot,
            tokenBBalanceSlot: pyusd0BalanceSlot,
            signer: testAccount
        )

        // For forward case (surplus), swap WFLOW → PYUSD0
        // For reverse case (deficit), swap PYUSD0 → WFLOW
        if !isDeficit {
            // Forward: WFLOW → PYUSD0
            let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!

            let swapRes = Test.executeTransaction(
                Test.Transaction(
                    code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                    authorizers: [testAccount.address],
                    signers: [testAccount],
                    arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, amount]
                )
            )
            Test.expect(swapRes, Test.beSucceeded())

            let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: pyusd0PublicPath)!
            let swapOutput = balanceAfter - balanceBefore
            let expectedOut = price * amount

            let tolerance = 0.000001
            Test.assert(
                equalAmounts(a: swapOutput, b: expectedOut, tolerance: tolerance),
                message: "Dynamic direction (surplus, price=\(price)): output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
            )
            log("Dynamic direction FORWARD (surplus, price=\(price)): expected=\(expectedOut) actual=\(swapOutput)")
        } else {
            // Reverse: PYUSD0 → WFLOW
            let balanceBefore = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath) ?? 0.0

            let swapRes = Test.executeTransaction(
                Test.Transaction(
                    code: Test.readFile("transactions/execute_univ3_swap.cdc"),
                    authorizers: [testAccount.address],
                    signers: [testAccount],
                    arguments: [factoryAddress, routerAddress, quoterAddress, pyusd0Address, wflowAddress, univ3PoolFee, amount]
                )
            )
            Test.expect(swapRes, Test.beSucceeded())

            let balanceAfter = getBalance(address: testAccount.address, vaultPublicPath: wflowPublicPath)!
            let swapOutput = balanceAfter - balanceBefore
            let expectedOut = amount / price

            let tolerance = 0.000001
            Test.assert(
                equalAmounts(a: swapOutput, b: expectedOut, tolerance: tolerance),
                message: "Dynamic direction (deficit, price=\(price)): output \(swapOutput) not within \(tolerance) of expected \(expectedOut)"
            )
            log("Dynamic direction REVERSE (deficit, price=\(price)): expected=\(expectedOut) actual=\(swapOutput)")
        }
    }
}
