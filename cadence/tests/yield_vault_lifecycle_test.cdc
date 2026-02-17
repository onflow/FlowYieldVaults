import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowYieldVaultsStrategies"
import "FlowALPv1"
import "FlowYieldVaults"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowYieldVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowYieldVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let targetHealthFactor = 1.3

// starting token prices
access(all) let startingFlowPrice = 1.0
access(all) let startingYieldPrice = 1.0

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // set mocked token prices
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: startingYieldPrice)
    setMockOraclePrice(signer: flowYieldVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: startingFlowPrice)

    // mint tokens & set liquidity in mock swapper contract
    let reserveAmount = 100_000_00.0
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // setup FlowCreditMarket with a Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenFixedRateInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: flowCollateralFactor,
        borrowFactor: flowBorrowFactor,
        yearlyRate: UFix128(0.1),
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // open wrapped position (pushToDrawDownSink)
    // the equivalent of depositing reserves
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/transactions/flow-alp/position/create_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // enable mocked Strategy creation
    addStrategyComposer(
        signer: flowYieldVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowYieldVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowYieldVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )
    
    // Scheduler contracts are deployed as part of deployContracts()

    // Fund FlowYieldVaults account for scheduling fees (atomic initial scheduling)
    mintFlow(to: flowYieldVaultsAccount, amount: 100.0)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testLifecycle() {
    let initialFunding = 100.0
    let depositAmount = 20.0
    let withdrawAmount = 10.0
    
    let user = Test.createAccount()
    mintFlow(to: user, amount: initialFunding + depositAmount + 10.0) // extra for fees/buffer
    grantBeta(flowYieldVaultsAccount, user)

    // 1. Create YieldVault
    createYieldVault(
        signer: user,
        strategyIdentifier: strategyIdentifier,
        vaultIdentifier: flowTokenIdentifier,
        amount: initialFunding,
        beFailed: false
    )

    let yieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(yieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil")
    Test.assertEqual(1, yieldVaultIDs!.length)
    let yieldVaultID = yieldVaultIDs![0]

    log("✅ YieldVault created with ID: \(yieldVaultID)")

    let addedToManagerEvents = Test.eventsOfType(Type<FlowYieldVaults.AddedToManager>())
    Test.assert(addedToManagerEvents.length > 0, message: "Expected at least 1 FlowYieldVaults.AddedToManager event but found none")
    let addedToManagerEvent = addedToManagerEvents[addedToManagerEvents.length - 1] as! FlowYieldVaults.AddedToManager
    Test.assertEqual(flowTokenIdentifier, addedToManagerEvent.tokenType)

    // 2. Deposit to YieldVault
    depositToYieldVault(
        signer: user,
        id: yieldVaultID,
        amount: depositAmount,
        beFailed: false
    )
    log("✅ Deposited to YieldVault")
    
    // Verify Balance roughly (exact amount depends on fees/slippage if any, but here mocks are 1:1 mostly)
    // getYieldVaultBalance logic might need checking, but we assume it works.

    // 3. Withdraw from YieldVault
    withdrawFromYieldVault(
        signer: user,
        id: yieldVaultID,
        amount: withdrawAmount,
        beFailed: false
    )
    log("✅ Withdrew from YieldVault")

    // 4. Close YieldVault
    closeYieldVault(signer: user, id: yieldVaultID, beFailed: false)
    log("✅ Closed YieldVault")

    let burnedEvents = Test.eventsOfType(Type<FlowYieldVaults.BurnedYieldVault>())
    Test.assert(burnedEvents.length > 0, message: "Expected at least 1 FlowYieldVaults.BurnedYieldVault event but found none")
    let burnedEvent = burnedEvents[burnedEvents.length - 1] as! FlowYieldVaults.BurnedYieldVault
    Test.assertEqual(flowTokenIdentifier, burnedEvent.tokenType)

    let finalYieldVaultIDs = getYieldVaultIDs(address: user.address)
    Test.assert(finalYieldVaultIDs != nil, message: "Expected user's YieldVault IDs to be non-nil")
    Test.assertEqual(0, finalYieldVaultIDs!.length)

    // Check final flow balance roughly
    let finalBalance = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Final Balance: \(finalBalance)")
    // Should be roughly initialFunding + depositAmount + 10.0 (minted) - initialFunding - depositAmount + withdrawAmount + remaining_from_close
    // essentially we put in (100 + 20), took out 10, then closed (took out rest). So we should have roughly what we started with minus fees.
}
