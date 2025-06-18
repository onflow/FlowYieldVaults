import "Tidal"

/// Adds the provided Strategy type to the Tidal StrategyFactory as built by the given StrategyComposer type
///
/// @param strategyIdentifier: The Type identifier of the Strategy to add to the StrategyFactory
/// @param composerStoragePath: The StoragePath where the StrategyComposer is stored
///
transaction(strategyIdentifier: String, composerStoragePath: StoragePath, enable: Bool) {

    /// The Strategy Type to add to the StrategyFactory
    let strategyType: Type
    /// The StrategyComposer that builds the Strategy Type
    let composer: @{Tidal.StrategyComposer}
    /// Authorized reference to the StrategyFactory to which the Strategy Type & StrategyComposer will be added
    let factory: auth(Mutate) &Tidal.StrategyFactory
    var finalStatus: Bool?

    prepare(signer: auth(BorrowValue) &Account) {
        // construct the types
        self.strategyType = CompositeType(strategyIdentifier) ?? panic("Invalid Strategy type \(strategyIdentifier)")

        // borrow reference to StrategyComposerIssuer & create the StategyComposer
        let originComposer = signer.storage.borrow<auth(Tidal.Issue) &{Tidal.StrategyComposer}>(from: composerStoragePath)
            ?? panic("Could not borrow reference to StrategyComposerIssuer from \(composerStoragePath)")
        self.composer <- originComposer.copyComposer()

        // assign StrategyFactory
        self.factory = signer.storage.borrow<auth(Mutate) &Tidal.StrategyFactory>(from: Tidal.FactoryStoragePath)
            ?? panic("Could not borrow reference to StrategyFactory from \(Tidal.FactoryStoragePath)")

        self.finalStatus = false
    }

    execute {
        // add the Strategy Type as built by the new StrategyComposer
        self.factory.addStrategyComposer(self.strategyType, composer: <-self.composer, enable: enable)
        // capture the final status for post-condition check
        self.finalStatus = self.factory.getSupportedStrategies()[self.strategyType]
    }

    post {
        self.finalStatus == enable:
        "Strategy \(strategyIdentifier) was not correctly added to StrategyFactory - was given enable \(enable) but found status of "
            .concat(self.finalStatus != nil ? "\(self.finalStatus!)" : "nil")
    }
}
