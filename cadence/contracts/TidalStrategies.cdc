import "FungibleToken"
import "FlowToken"

import "DFBUtils"
import "DFB"

// TODO: rename to TidalYieldStrategies
access(all) contract TidalStrategies {

    access(all) let FactoryStoragePath: StoragePath
    access(all) let FactoryPublicPath: PublicPath

    /* --- PUBLIC METHODS --- */

    access(all) view fun getCollateralTypes(forStrategy: UInt64): [Type]? {
        return self.strategies[forStrategy]?.getSupportedCollateralTypes() ?? nil
    }

    access(all) view fun isSupportedCollateralType(_ type: Type, forStrategy: UInt64): Bool? {
        return self.strategies[forStrategy]?.isSupportedCollateralType(type) ?? nil
    }

    access(all) fun createStrategy(type: Type, vault: @{FungibleToken.Vault}): {Strategy} {
        destroy vault // TODO: Update vault handling
        return DummyStrategy(id: DFB.UniqueIdentifier())
    }

    access(all) fun createStrategyFactory(): @StrategyFactory {
        return <- create StrategyFactory()
    }

    /* --- CONSTRUCTS --- */

    /// A StrategyBuilder is responsible for stacking DeFiBlocks connectors in a manner that composes a final Strategy.
    /// Since DeFiBlock Sink/Source only support single assets and some Strategies may be multi-asset, we deal with
    /// building a Strategy distinctly from encapsulating the top-level DFB connectors acting as entrypoints in to the
    /// composed DeFiBlocks infrastructure.
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyBuilder.
    access(all) struct interface StrategyBuilder {
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): [Type]
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): [Type]
        access(all) fun createStrategy(_ type: Type, withFunds: @{FungibleToken.Vault}): {Strategy}
    }

    /// A Strategy is meant to encapsulate the Sink/Source entrypoints allowing for flows into and out of composed
    /// DeFiBlocks components. These compositions are intended to capitalize on some yield-bearing opportunity so that
    /// a Strategy bears yield on that which is deposited into it, albeit not without some risk. A Strategy then can be
    /// thought of as the top-level of a nesting of DeFiBlocks connectors & adapters where one can deposit & withdraw
    /// funds into the composed DeFi workflows
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyBuilder.
    access(all) struct interface Strategy : DFB.IdentifiableStruct {
        access(all) view fun getSupportedCollateralTypes(): [Type]
        access(all) view fun isSupportedCollateralType(_ type: Type): Bool
        access(all) fun availableBalance(ofToken: Type): UFix64
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault}
    }

    access(all) struct DummySink : DFB.Sink {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        init(_ id: DFB.UniqueIdentifier?) {
            self.uniqueID = id
        }
        access(all) view fun getSinkType(): Type {
            return Type<@FlowToken.Vault>()
        }
        access(all) fun minimumCapacity(): UFix64 {
            return 0.0
        }
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            return
        }
    }
    access(all) struct DummySource : DFB.Source {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        init(_ id: DFB.UniqueIdentifier?) {
            self.uniqueID = id
        }
        access(all) view fun getSourceType(): Type {
            return Type<@FlowToken.Vault>()
        }
        access(all) fun minimumAvailable(): UFix64 {
            return 0.0
        }
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- DFBUtils.getEmptyVault(self.getSourceType())
        }
    }

    access(all) struct DummyStrategy : Strategy {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) var sink: {DFB.Sink}
        access(self) var source: {DFB.Source}

        init(id: DFB.UniqueIdentifier?, sink: {DFB.Sink}, source: {DFB.Source}) {
            self.uniqueID = id
            self.sink = sink
            self.source = source
        }

        access(all) view fun getSupportedCollateralTypes(): [Type] {
            return [self.sink.getSinkType()]
        }

        access(all) view fun isSupportedCollateralType(_ type: Type): Bool {
            return self.sink.getSinkType() == type
        }

        /// Returns the amount available for withdrawal via the inner Source
        access(all) fun availableBalance(ofToken: Type): UFix64 {
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
        }

        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.sink.depositCapacity(from: from)
        }

        /// Withdraws up to the max amount, returning the withdrawn Vault. If the requested token type is unsupported,
        /// an empty Vault is returned.
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            if ofToken != self.source.getSourceType() {
                return <- DFBUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }
    }

    access(all) struct DummyStrategyBuilder : StrategyBuilder {
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): [Type] {
            return []
        }
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): [Type] {
            return []
        }
        access(all) fun createStrategy(_ type: Type, withFunds: @{FungibleToken.Vault}): {Strategy} {
            let id = DFB.UniqueIdentifier()
            let strat = DummyStrategy(
                id: id,
                sink: DummySink(id),
                source: DummySource(id)
            )
            strat.deposit(from: &withFunds as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy withFunds
            return strat
        }
    }

    access(all) resource StrategyFactory {
        /// The strategies this factory can build
        access(self) let builders: {Type: {StrategyBuilder}}

        init() {
            self.builders = {}
        }

        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): [Type] {
            return self.builders[forStrategy]?.getSupportedInitializationVaults(forStrategy: forStrategy) ?? []
        }

        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): [Type] {
            return self.builders[forStrategy]?.getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith) ?? []
        }

        access(all) fun createStrategy(_ type: Type, withFunds: @{FungibleToken.Vault}): {Strategy} {
            pre {
                self.builders[type] != nil: "Strategy \(type.identifier) is unsupported"
            }
            return self.builders[type]!.createStrategy(type, withFunds: <-withFunds)
        }

        access(Mutate) fun setStrategyBuilder(_ strategy: Type, builder: {StrategyBuilder}) {
            self.builders[strategy] = builder
        }

        access(Mutate) fun removeStrategy(_ strategy: Type): Bool {
            return self.builders.remove(key: strategy) != nil
        }
    }

    access(self) view fun _borrowFactory(): &StrategyFactory {
        return self.account.storage.borrow<&StrategyFactory>(from: self.FactoryStoragePath)
            ?? panic("Could not borrow reference to StrategyFactory from \(self.FactoryStoragePath)")
    }


    init() {
        let pathIdentifier = "TidalYieldStrategyFactory_\(self.account.address)"
        self.FactoryStoragePath = StoragePath(identifier: pathIdentifier)!
        self.FactoryPublicPath = PublicPath(identifier: pathIdentifier)!

        // configure a StrategyFactory in storage and publish a public Capability
        self.account.storage.save(<-create StrategyFactory(), to: self.FactoryStoragePath)
        let cap = self.account.capabilities.storage.issue<&StrategyFactory>(self.FactoryStoragePath)
        self.account.capabilities.publish(cap, at: self.FactoryPublicPath)
    }
}
