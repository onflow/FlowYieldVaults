import "FlowALPv1"
import "MockOracle"
import "MockDexSwapper"

/// Creates the FlowALPv1 Pool with MockOracle and MockDexSwapper
transaction(defaultTokenIdentifier: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let factory = signer.storage.borrow<&FlowALPv1.PoolFactory>(from: FlowALPv1.PoolFactoryPath)
            ?? panic("Could not find PoolFactory")
        let defaultToken = CompositeType(defaultTokenIdentifier) 
            ?? panic("Invalid defaultTokenIdentifier")
        let oracle = MockOracle.PriceOracle()
        let dex = MockDexSwapper.SwapperProvider()
        factory.createPool(defaultToken: defaultToken, priceOracle: oracle, dex: dex)
    }
}
