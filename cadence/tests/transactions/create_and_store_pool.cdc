import "FungibleToken"

import "DeFiActions"
import "FlowALP"
import "MockOracle"

/// THIS TRANSACTION IS NOT INTENDED FOR PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Creates the protocol pool in the FlowALP account via the stored PoolFactory resource
///
/// @param defaultTokenIdentifier: The Type identifier (e.g. resource.getType().identifier) of the Pool's default token
///
transaction(defaultTokenIdentifier: String) {

    let factory: &FlowALP.PoolFactory
    let defaultToken: Type
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue) &Account) {
        self.factory = signer.storage.borrow<&FlowALP.PoolFactory>(from: FlowALP.PoolFactoryPath)
            ?? panic("Could not find PoolFactory in signer's account")
        self.defaultToken = CompositeType(defaultTokenIdentifier) ?? panic("Invalid defaultTokenIdentifier \(defaultTokenIdentifier)")
        self.oracle = MockOracle.PriceOracle()
    }

    execute {
        self.factory.createPool(defaultToken: self.defaultToken, priceOracle: self.oracle)
    }
}
