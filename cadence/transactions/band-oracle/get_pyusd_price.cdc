import "FungibleToken"
import "FlowToken"
import "BandOracle"

/// Retrieves the PYUSD/USD price from the Band Protocol oracle, paying the oracle fee from
/// the signer's FLOW vault. Use this transaction when BandOracle.getFee() > 0.0.
///
/// The price is emitted to the transaction log. Band oracle rates are USD-denominated, so
/// PYUSD/USD returns the USD value of one PYUSD token (~1.0 for a healthy peg).
///
/// Excess FLOW (payment beyond the required fee) is returned to the signer's vault.
///
transaction {

    prepare(signer: auth(BorrowValue) &Account) {
        let fee = BandOracle.getFee()

        // Borrow the signer's FLOW vault and withdraw the exact oracle fee
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow signer's FlowToken vault")

        let payment <- flowVault.withdraw(amount: fee) as! @FlowToken.Vault

        let priceData = BandOracle.getReferenceData(
            baseSymbol: "PYUSD",
            quoteSymbol: "USD",
            payment: <-payment
        )

        log("PYUSD/USD price (UFix64):    ".concat(priceData.fixedPointRate.toString()))
        log("PYUSD/USD rate (e18 integer): ".concat(priceData.integerE18Rate.toString()))
        log("Base timestamp (UNIX):        ".concat(priceData.baseTimestamp.toString()))
        log("Quote timestamp (UNIX):       ".concat(priceData.quoteTimestamp.toString()))
    }
}
