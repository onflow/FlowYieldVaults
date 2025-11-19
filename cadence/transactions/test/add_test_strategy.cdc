import "FlowVaults"
import "TestStrategyWithAutoBalancer"

/// Add TestStrategyWithAutoBalancer to the FlowVaults StrategyFactory
/// Custom transaction that avoids interface type issues
transaction() {
    let composer: @{FlowVaults.StrategyComposer}
    let factory: auth(Mutate) &FlowVaults.StrategyFactory

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the issuer with concrete type
        let issuer = signer.storage.borrow<&TestStrategyWithAutoBalancer.StrategyComposerIssuer>(
            from: TestStrategyWithAutoBalancer.IssuerStoragePath
        ) ?? panic("Could not borrow StrategyComposerIssuer")
        
        // Issue the composer
        self.composer <- issuer.issueComposer(Type<@TestStrategyWithAutoBalancer.StrategyComposer>())
        
        // Borrow the StrategyFactory
        self.factory = signer.storage.borrow<auth(Mutate) &FlowVaults.StrategyFactory>(
            from: FlowVaults.FactoryStoragePath
        ) ?? panic("Could not borrow StrategyFactory")
    }

    execute {
        // Add the strategy
        self.factory.addStrategyComposer(
            Type<@TestStrategyWithAutoBalancer.Strategy>(),
            composer: <-self.composer
        )
        
        log("✅ TestStrategyWithAutoBalancer registered!")
    }
}

