import "FungibleToken"
import "FlowToken"
import "BandOracle"

/// Retrieves the PYUSD/USD price from the Band Protocol oracle on Flow.
///
/// BandOracle stores rates as symbol/USD values and computes cross-rates on demand.
/// Querying PYUSD/USD returns the USD price of one PYUSD token (~1.0 for a healthy peg).
///
/// NOTE: BandOracle.getReferenceData requires a FLOW fee payment. This script creates an
/// empty vault and succeeds only when BandOracle.getFee() == 0.0. If the fee is non-zero,
/// use the get_pyusd_price transaction instead, which withdraws from the signer's FLOW vault.
///
/// @return A struct with:
///   - fixedPointRate:   UFix64  — PYUSD/USD price as a decimal (e.g. 0.99980000)
///   - integerE18Rate:   UInt256 — rate multiplied by 10^18
///   - baseTimestamp:    UInt64  — UNIX epoch of the last PYUSD data update on BandChain
///   - quoteTimestamp:   UInt64  — UNIX epoch of the last USD data update on BandChain
///
access(all)
fun main(): BandOracle.ReferenceData {
    let fee = BandOracle.getFee()
    assert(fee == 0.0, message: "BandOracle fee is non-zero (\(fee) FLOW). Use the get_pyusd_price transaction to pay the fee.")

    // Create an empty vault satisfying the payment parameter (fee == 0.0 is already asserted above)
    let payment <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())

    // PYUSD is the base symbol; USD is the implicit quote for all Band oracle rates.
    // The returned fixedPointRate = PYUSD price in USD.
    let priceData = BandOracle.getReferenceData(
        baseSymbol: "PYUSD",
        quoteSymbol: "USD",
        payment: <-payment
    )

    return priceData
}
