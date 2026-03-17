import "BandOracle"
import "FlowToken"

/// TEST TRANSACTION - NOT FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Refreshes the Band FLOW/USD and USD/USD entries using their current rates but
/// the current fork timestamp. This keeps FlowALP's FLOW-vs-MOET oracle checks
/// from aging out during mainnet-fork tests.
///
/// Requires the BandOracle admin signer on the fork.
///
transaction() {
    let updater: &{BandOracle.DataUpdater}

    prepare(signer: auth(BorrowValue) &Account) {
        self.updater = signer.storage.borrow<&{BandOracle.DataUpdater}>(from: BandOracle.OracleAdminStoragePath)
            ?? panic("Could not find DataUpdater at ".concat(BandOracle.OracleAdminStoragePath.toString()))
    }

    execute {
        let fee = BandOracle.getFee()
        assert(fee == 0.0, message: "BandOracle fee must be zero for this fork-test refresh transaction")

        let flowPayment <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let flowUsd = BandOracle.getReferenceData(
            baseSymbol: "FLOW",
            quoteSymbol: "USD",
            payment: <-flowPayment
        )

        let usdPayment <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let usdUsd = BandOracle.getReferenceData(
            baseSymbol: "USD",
            quoteSymbol: "USD",
            payment: <-usdPayment
        )

        self.updater.updateData(
            symbolsRates: {
                "FLOW": UInt64(flowUsd.fixedPointRate * 1000000000.0),
                "USD": UInt64(usdUsd.fixedPointRate * 1000000000.0)
            },
            resolveTime: UInt64(getCurrentBlock().timestamp),
            requestID: revertibleRandom<UInt64>(),
            relayerID: revertibleRandom<UInt64>()
        )
    }
}
