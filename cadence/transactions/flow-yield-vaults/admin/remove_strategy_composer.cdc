import "FlowYieldVaults"

/// Removes a Strategy type from the FlowYieldVaults StrategyFactory.
///
/// Use this to clean up stale or broken strategy entries — for example, strategies whose
/// backing contract no longer type-checks against the current FlowYieldVaults.Strategy interface.
///
/// @param strategyIdentifier: The Type identifier of the Strategy to remove, e.g.
///     "A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.TracerStrategy"
///
transaction(strategyIdentifier: String) {

    let factory: auth(Mutate) &FlowYieldVaults.StrategyFactory

    prepare(signer: auth(BorrowValue) &Account) {
        self.factory = signer.storage.borrow<auth(Mutate) &FlowYieldVaults.StrategyFactory>(
            from: FlowYieldVaults.FactoryStoragePath
        ) ?? panic("Could not borrow StrategyFactory from \(FlowYieldVaults.FactoryStoragePath)")
    }

    execute {
        let strategyType = CompositeType(strategyIdentifier)
            ?? panic("Invalid strategy type identifier: \(strategyIdentifier)")
        let removed = self.factory.removeStrategy(strategyType)
        log(removed
            ? "Removed \(strategyIdentifier) from StrategyFactory"
            : "Strategy \(strategyIdentifier) was not found in StrategyFactory"
        )
    }
}
