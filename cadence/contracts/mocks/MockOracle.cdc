import "FungibleToken"

import "DFB"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MockOracle {

    /// token price denominated in USD
    access(self) let mockedPrices: {Type: UFix64}
    /// the token type in which prices are denominated
    access(self) let unitOfAccount: Type
    /// bps up or down by which current price moves when bumpPrice is called
    access(self) let bumpVariance: UInt16

    access(all) struct PriceOracle : DFB.PriceOracle {

        /// Returns the asset type serving as the price basis - e.g. USD in FLOW/USD
        access(all) view fun unitOfAccount(): Type {
            return MockOracle.unitOfAccount
        }

        /// Returns the latest price data for a given asset denominated in unitOfAccount()
        access(all) fun price(ofToken: Type): UFix64? {
            if ofToken == self.unitOfAccount() {
                return 1.0
            }
            return MockOracle.mockedPrices[ofToken]
        }
    }

    // resets the price of the token within 0-bumpVariance (bps) of the current price
    // allows for mocked data to have variability
    access(all) fun bumpPrice(forToken: Type) {
        if forToken == self.unitOfAccount {
            return
        }
        let current = self.mockedPrices[forToken]
            ?? panic("MockOracle does not have a price set for token \(forToken.identifier)")
        let sign = revertibleRandom<UInt8>(modulo: 2) // 0 - down | 1 - up
        let variance = self.convertToBPS(revertibleRandom<UInt16>(modulo: self.bumpVariance)) // bps up or down
        if sign == 0 {
            self.mockedPrices[forToken] = current - (current * variance)
        } else {
            self.mockedPrices[forToken] = current + (current * variance)
        }
    }

    access(all) fun setPrice(forToken: Type, price: UFix64) {
        self.mockedPrices[forToken] = price
    }

    access(self) view fun convertToBPS(_ variance: UInt16): UFix64 {
        var res = UFix64(variance)
        for i in InclusiveRange(0, 3) {
            res = res / 10.0
        } 
        return res
    }

    init(unitOfAccountIdentifier: String) {
        self.mockedPrices = {}
        // e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
        self.unitOfAccount = CompositeType(unitOfAccountIdentifier) ?? panic("Invalid unitOfAccountIdentifier \(unitOfAccountIdentifier)")
        self.bumpVariance = 100 // 0.1% variance
    }
}
