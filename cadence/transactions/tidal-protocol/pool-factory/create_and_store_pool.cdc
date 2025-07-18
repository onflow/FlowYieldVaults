import "FungibleToken"

import "DeFiActions"
import "TidalProtocol"
import "MockOracle"

/// THIS TRANSACTION IS NOT INTENDED FOR PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Creates the protocol pool in the TidalProtocol account via the stored PoolFactory resource
///
/// @param defaultTokenIdentifier: The Type identifier (e.g. resource.getType().identifier) of the Pool's default token
///
transaction(defaultTokenIdentifier: String) {

    let factory: &TidalProtocol.PoolFactory
    let defaultToken: Type
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue) &Account) {
        self.factory = signer.storage.borrow<&TidalProtocol.PoolFactory>(from: TidalProtocol.PoolFactoryPath)
            ?? panic("Could not find PoolFactory in signer's account")
        self.defaultToken = CompositeType(defaultTokenIdentifier) ?? panic("Invalid defaultTokenIdentifier \(defaultTokenIdentifier)")
        self.oracle = MockOracle.PriceOracle()
    }

    execute {
        self.factory.createPool(defaultToken: self.defaultToken, priceOracle: self.oracle)
    }
}
