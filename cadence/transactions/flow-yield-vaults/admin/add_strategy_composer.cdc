import "FlowYieldVaults"

/// Adds the provided Strategy type to the FlowYieldVaults StrategyFactory as built by the given StrategyComposer type
///
/// @param strategyIdentifier: The Type identifier of the Strategy to add to the StrategyFactory
/// @param composerIdentifier: The Type identifier of the StrategyComposer that builds the Strategy Type
///
transaction(strategyIdentifier: String, composerIdentifier: String, issuerStoragePath: StoragePath) {

    /// The Strategy Type to add to the StrategyFactory
    let strategyType: Type
    /// The StrategyComposer that builds the Strategy Type
    let composer: @{FlowYieldVaults.StrategyComposer}
    /// Authorized reference to the StrategyFactory to which the Strategy Type & StrategyComposer will be added
    let factory: auth(Mutate) &FlowYieldVaults.StrategyFactory

    prepare(signer: auth(BorrowValue) &Account) {
        // construct the types
        self.strategyType = CompositeType(strategyIdentifier) ?? panic("Invalid Strategy type \(strategyIdentifier)")
        let composerType = CompositeType(composerIdentifier) ?? panic("Invalid StrategyComposer type \(composerIdentifier)")

        // borrow reference to StrategyComposerIssuer & create the StategyComposer
        let issuer = signer.storage.borrow<&{FlowYieldVaults.StrategyComposerIssuer}>(from: issuerStoragePath)
            ?? panic("Could not borrow reference to StrategyComposerIssuer from \(issuerStoragePath)")
        self.composer <- issuer.issueComposer(composerType)

        // assign StrategyFactory
        self.factory = signer.storage.borrow<auth(Mutate) &FlowYieldVaults.StrategyFactory>(from: FlowYieldVaults.FactoryStoragePath)
            ?? panic("Could not borrow reference to StrategyFactory from \(FlowYieldVaults.FactoryStoragePath)")
    }

    execute {
        // add the Strategy Type as built by the new StrategyComposer
        self.factory.addStrategyComposer(self.strategyType, composer: <-self.composer)
    }
}
