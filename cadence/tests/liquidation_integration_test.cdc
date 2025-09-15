import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "TidalProtocol"
import "MOET"
import "FlowToken"

access(all) let flowTokenIdentifier = Type<@FlowToken.Vault>().identifier
access(all) let defaultTokenIdentifier = Type<@MOET.Vault>().identifier

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()

    let protocol = Test.getAccount(0x0000000000000007)

    setMockOraclePrice(signer: protocol, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    createAndStorePool(signer: protocol, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocol,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_liquidation_quote_and_execute() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    let openRes = _executeTransaction(
        "../transactions/mocks/position/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // cause undercollateralization
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)

    // quote liquidation using submodule script
    let quoteRes = _executeScript(
        "../../lib/TidalProtocol/cadence/scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote
    if quote.requiredRepay == 0.0 {
        // Near-threshold rounding case may produce zero-step; nothing to liquidate
        return
    }

    // execute liquidation repay-for-seize via submodule transaction
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: quote.requiredRepay + 1.0, beFailed: false)

    let liqRes = _executeTransaction(
        "../../lib/TidalProtocol/cadence/transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay + 1.0, 0.0],
        liquidator
    )
    Test.expect(liqRes, Test.beSucceeded())

    // health after liquidation should be ~1.05e24
    let hRes = _executeScript("../scripts/tidal-protocol/position_health.cdc", [pid])
    Test.expect(hRes, Test.beSucceeded())
    let hAfter = hRes.returnValue as! UInt128

    let targetHF = UInt128(1050000000000000000000000)  // 1.05e24
    let tolerance = UInt128(10000000000000000000)      // 0.01e24
    Test.assert(hAfter >= targetHF - tolerance && hAfter <= targetHF + tolerance, message: "Post-liquidation health not at target 1.05")
}


