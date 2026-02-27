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

access(all) let univ3PoolFee: UInt64 = 3000

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
