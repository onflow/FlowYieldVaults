// Tests that EVM state helpers correctly set Uniswap V3 pool price and ERC4626 vault price,
// verified by executing a swap (UniV3) and a deposit (ERC4626) using the same fork/setup as scenario3c.
#test_fork(network: "mainnet-fork", height: 142251136)

import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "evm_state_helpers.cdc"

import "FlowToken"

// Mainnet addresses (same as forked_rebalance_scenario3c_test.cdc)
access(all) let whaleFlowAccount = Test.getAccount(0x92674150c9213fc9)
access(all) let coaOwnerAccount = Test.getAccount(0xe467b9dd11fa00df)

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

// Bridged vault type identifiers (service account prefix may vary; use deployment)
access(all) let pyusd0VaultTypeId = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"
access(all) let fusdevVaultTypeId = "A.1e4aa0b87d10b141.EVMVMBridgedToken_d069d989e2f44b70c65347d1853c0c67e10a9f8d.Vault"

access(all)
fun setup() {
    deployContractsForFork()
    transferFlow(signer: whaleFlowAccount, recipient: coaOwnerAccount.address, amount: 1000.0)

    // Deposit FLOW to COA to cover bridge/gas fees for swaps (scheduled txs can consume some)
    let depositFlowRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/deposit_flow_to_coa.cdc"),
            authorizers: [coaOwnerAccount.address],
            signers: [coaOwnerAccount],
            arguments: [5.0]
        )
    )
    Test.expect(depositFlowRes, Test.beSucceeded())
}

access(all) let univ3PoolFee: UInt64 = 3000

access(all)
fun test_UniswapV3PriceSetAndSwap() {
    setPoolToPrice(
        factoryAddress: factoryAddress,
        tokenAAddress: wflowAddress,
        tokenBAddress: pyusd0Address,
        fee: univ3PoolFee,
        priceTokenBPerTokenA: 2.0,
        tokenABalanceSlot: wflowBalanceSlot,
        tokenBBalanceSlot: pyusd0BalanceSlot,
        signer: coaOwnerAccount
    )

    // Set COA WFLOW balance to 100.0 for the swap
    let flowAmount = 100.0
    let setBalanceRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_coa_token_balance.cdc"),
            authorizers: [coaOwnerAccount.address],
            signers: [coaOwnerAccount],
            arguments: [wflowAddress, wflowBalanceSlot, flowAmount]
        )
    )
    Test.expect(setBalanceRes, Test.beSucceeded())

    let swapRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/execute_univ3_swap.cdc"),
            authorizers: [coaOwnerAccount.address],
            signers: [coaOwnerAccount],
            arguments: [factoryAddress, routerAddress, quoterAddress, wflowAddress, pyusd0Address, univ3PoolFee, flowAmount]
        )
    )
    Test.expect(swapRes, Test.beSucceeded())

    let balanceRes = Test.executeScript(
        Test.readFile("scripts/get_bridged_vault_balance.cdc"),
        [coaOwnerAccount.address, pyusd0VaultTypeId]
    )
    Test.expect(balanceRes, Test.beSucceeded())
    let pyusd0Balance = (balanceRes.returnValue as? UFix64) ?? 0.0
    let expectedOut = flowAmount * 2.0
    let tolerance = expectedOut * forkedPercentTolerance
    Test.assert(
        equalAmounts(a: pyusd0Balance, b: expectedOut, tolerance: tolerance),
        message: "PYUSD0 balance \(pyusd0Balance.toString()) not within tolerance of \(expectedOut.toString())"
    )
}

access(all)
fun test_ERC4626PriceSetAndDeposit() {
    setVaultSharePrice(
        vaultAddress: morphoVaultAddress,
        assetAddress: pyusd0Address,
        assetBalanceSlot: pyusd0BalanceSlot,
        totalSupplySlot: morphoVaultTotalSupplySlot,
        vaultTotalAssetsSlot: morphoVaultTotalAssetsSlot,
        baseAssets: 1000000000.0,
        priceMultiplier: 2.0,
        signer: coaOwnerAccount
    )

    // Set COA PYUSD0 balance to 1000000000.0 for the deposit
    let fundRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/set_coa_token_balance.cdc"),
            authorizers: [coaOwnerAccount.address],
            signers: [coaOwnerAccount],
            arguments: [pyusd0Address, pyusd0BalanceSlot, 1000000000.0]
        )
    )
    Test.expect(fundRes, Test.beSucceeded())

    let amountIn = 1.0
    let depositRes = Test.executeTransaction(
        Test.Transaction(
            code: Test.readFile("transactions/execute_morpho_deposit.cdc"),
            authorizers: [coaOwnerAccount.address],
            signers: [coaOwnerAccount],
            arguments: [pyusd0VaultTypeId, morphoVaultAddress, amountIn]
        )
    )
    Test.expect(depositRes, Test.beSucceeded())

    let balanceRes = Test.executeScript(
        Test.readFile("scripts/get_bridged_vault_balance.cdc"),
        [coaOwnerAccount.address, fusdevVaultTypeId]
    )
    Test.expect(balanceRes, Test.beSucceeded())
    let fusdevBalance = (balanceRes.returnValue as? UFix64) ?? 0.0
    let expectedShares = 0.5
    let tolerance = expectedShares * forkedPercentTolerance
    Test.assert(
        equalAmounts(a: fusdevBalance, b: expectedShares, tolerance: tolerance),
        message: "FUSDEV shares \(fusdevBalance.toString()) not within tolerance of \(expectedShares.toString())"
    )
}
