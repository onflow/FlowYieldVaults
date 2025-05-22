import "MockOracle"

/// Gets the mocked price data from the MockOracle contract denominated in the current unitOfAccount token type
///
/// @param forTokenIdentifier: The Vault Type identifier for the token whose price will be retrieved
access(all)
fun main(forTokenIdentifier: String): UFix64 {
    // Type identifier - e.g. vault.getType().identifier == 'A.0ae53cb6e3f42a79.FlowToken.Vault'
    return MockOracle.PriceOracle().price(
        ofToken: CompositeType(forTokenIdentifier) ?? panic("Invalid forTokenIdentifier \(forTokenIdentifier)")
    )
}
