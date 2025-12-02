import Test
import BlockchainHelpers
import "test_helpers.cdc"

import "FlowVaultsStrategies"
import "FlowVaultsSchedulerRegistry"
import "FlowToken"
import "MOET"
import "YieldToken"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000008)
access(all) let flowVaultsAccount = Test.getAccount(0x0000000000000009)
access(all) let yieldTokenAccount = Test.getAccount(0x0000000000000010)

access(all) var strategyIdentifier = Type<@FlowVaultsStrategies.TracerStrategy>().identifier
access(all) var flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) var yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
access(all) var moetTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) let collateralFactor = 0.8
access(all) let borrowFactor = 1.0

access(all) fun setup() {
    deployContracts()

    // Configure oracle prices for Flow / Yield so AutoBalancer initialization succeeds.
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: yieldTokenIdentifier, price: 1.0)
    setMockOraclePrice(signer: flowVaultsAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // Mint tokens & set liquidity in the mock swapper.
    let reserveAmount = 100_000_00.0
    setupMoetVault(protocolAccount, beFailed: false)
    setupYieldVault(protocolAccount, beFailed: false)
    mintFlow(to: protocolAccount, amount: reserveAmount)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    mintYield(signer: yieldTokenAccount, to: protocolAccount.address, amount: reserveAmount, beFailed: false)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: MOET.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: YieldToken.VaultStoragePath)
    setMockSwapperLiquidityConnector(signer: protocolAccount, vaultStoragePath: /storage/flowTokenVault)

    // Setup FlowCreditMarket with a pool & add FLOW as a supported token.
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: collateralFactor,
        borrowFactor: borrowFactor,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Open a wrapped FlowCreditMarket position so strategies have an underlying position to work with.
    let openRes = executeTransaction(
        "../../lib/FlowCreditMarket/cadence/tests/transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [reserveAmount/2.0, /storage/flowTokenVault, true],
        protocolAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Enable Strategy creation
    addStrategyComposer(
        signer: flowVaultsAccount,
        strategyIdentifier: strategyIdentifier,
        composerIdentifier: Type<@FlowVaultsStrategies.TracerStrategyComposer>().identifier,
        issuerStoragePath: FlowVaultsStrategies.IssuerStoragePath,
        beFailed: false
    )

    // Scheduler contracts are deployed as part of deployContracts()
    
    // Fund FlowVaults account for scheduling fees (atomic initial scheduling)
    mintFlow(to: flowVaultsAccount, amount: 100.0)
}

access(all) fun testAtomicRegistrationAndGC() {
    let user = Test.createAccount()
    let fundingAmount = 100.0
    mintFlow(to: user, amount: fundingAmount)

    // Grant Beta Access
    let betaRef = grantBeta(flowVaultsAccount, user)
    Test.expect(betaRef, Test.beSucceeded())

    // 1. Create YieldVault (Atomic Registration)
    let createYieldVaultRes = executeTransaction(
        "../transactions/flow-vaults/create_yield_vault.cdc",
        [strategyIdentifier, flowTokenIdentifier, fundingAmount],
        user
    )
    Test.expect(createYieldVaultRes, Test.beSucceeded())

    let yieldVaultIDsResult = getYieldVaultIDs(address: user.address)
    let yieldVaultID = yieldVaultIDsResult![0]

    // Verify YieldVault is registered in Scheduler Registry by querying registered IDs
    let registeredIDsRes = _executeScript(
        "../scripts/flow-vaults/get_registered_yield_vault_ids.cdc",
        []
    )
    Test.expect(registeredIDsRes, Test.beSucceeded())
    let registeredIDs = registeredIDsRes.returnValue! as! [UInt64]
    Test.assert(
        registeredIDs.contains(yieldVaultID),
        message: "YieldVault should be registered in FlowVaultsSchedulerRegistry atomically"
    )

    // Verify Wrapper Capability exists
    let capCheck = _executeScript(
        "../scripts/flow-vaults/has_wrapper_cap_for_yield_vault.cdc",
        [yieldVaultID]
    )
    Test.expect(capCheck, Test.beSucceeded())
    let hasCap = capCheck.returnValue! as! Bool
    Test.assert(hasCap, message: "Wrapper capability should be present in Registry")

    // 2. Close YieldVault (Garbage Collection)
    let closeYieldVaultRes = executeTransaction(
        "../transactions/flow-vaults/close_yield_vault.cdc",
        [yieldVaultID],
        user
    )
    Test.expect(closeYieldVaultRes, Test.beSucceeded())

    // Verify YieldVault is unregistered
    let registeredIDsAfterRes = _executeScript(
        "../scripts/flow-vaults/get_registered_yield_vault_ids.cdc",
        []
    )
    Test.expect(registeredIDsAfterRes, Test.beSucceeded())
    let registeredIDsAfter = registeredIDsAfterRes.returnValue! as! [UInt64]
    Test.assert(
        !registeredIDsAfter.contains(yieldVaultID),
        message: "YieldVault should be unregistered from FlowVaultsSchedulerRegistry after closing"
    )

    // Verify Wrapper Capability is gone
    let capCheckAfter = _executeScript(
        "../scripts/flow-vaults/has_wrapper_cap_for_yield_vault.cdc",
        [yieldVaultID]
    )
    Test.expect(capCheckAfter, Test.beSucceeded())
    let hasCapAfter = capCheckAfter.returnValue! as! Bool
    Test.assert(!hasCapAfter, message: "Wrapper capability should be removed from Registry")
}

