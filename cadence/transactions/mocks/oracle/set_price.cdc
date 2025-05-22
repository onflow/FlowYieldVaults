import "MockOracle"

/// Upserts the provided Token & price pairing in the MockOracle contract
///
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
/// @param price: The price to set the token to in the MockOracle denominated in USD
transaction(forTokenIdentifier: String, price: UFix64) {
    let tokenType: Type
    
    prepare(signer: &Account) {
        self.tokenType = CompositeType(forTokenIdentifier) ?? panic("Invalid Type \(forTokenIdentifier)")
    }

    execute {
        MockOracle.setPrice(forToken: self.tokenType, price: price)
    }
}
