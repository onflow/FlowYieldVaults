import "MockOracle"

/// Bumps the current token price in the MockOracle contract by some percentage (up or down) between
/// 0-bumpVariance (default 1%) randomly chosen using revertibleRandom
///
/// @param vaultIdentifier: The Vault's Type identifier
///     e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
transaction(forTokenIdentifier: String) {
    let tokenType: Type

    prepare(signer: &Account) {
        self.tokenType = CompositeType(forTokenIdentifier) ?? panic("Invalid Type \(forTokenIdentifier)")
    }

    execute {
        MockOracle.bumpPrice(forToken: self.tokenType)
    }
}
