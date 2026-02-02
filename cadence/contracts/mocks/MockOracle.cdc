import "FungibleToken"

import "DeFiActions"

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

    access(all) struct PriceOracle : DeFiActions.PriceOracle {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init() {
            self.uniqueID = nil 
        }
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
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    // Adds a random increment between 0.0001 and 0.001 to simulate steady yield accrual
    // With 15-minute polling: avg ~5.3% daily increase, range 0.96% to 9.6% daily
    access(all) fun bumpPrice(forToken: Type) {
        if forToken == self.unitOfAccount {
            return
        }
        let current = self.mockedPrices[forToken]
            ?? panic("MockOracle does not have a price set for token \(forToken.identifier)")
        
        // Generate random multiplier 1-10, then multiply by 0.0001 to get range 0.0001-0.001
        let randomMultiplier = UInt8(revertibleRandom<UInt8>(modulo: 10)) + 1 // 1 to 10
        let increment = UFix64(randomMultiplier) * 0.0001 // 0.0001 to 0.001
        
        self.mockedPrices[forToken] = current + increment
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
