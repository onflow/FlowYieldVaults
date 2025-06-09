import "FungibleToken"
import "FlowToken"

import "DFBUtils"
import "DFB"

/// This contract is used by TidalYield to manage supported Strategies and create Factories for new Tides.
///
access(all) contract TidalYieldFactory {

    access(all) let FactoryStoragePath: StoragePath
    access(all) let FactoryPublicPath: PublicPath

    /* --- PUBLIC METHODS --- */

    access(all) view fun getSupportedStrategies(): [Type] {
        return self._borrowFactory().getSupportedStrategies()
    }
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): [Type] {
        return self._borrowFactory().getSupportedInitializationVaults(forStrategy: forStrategy)
    }
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): [Type] {
        return self._borrowFactory().getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith)
    }
    access(all) fun createStrategy(type: Type, withFunds: @{FungibleToken.Vault}): {Strategy} {
        return self._borrowFactory().createStrategy(type, withFunds: <-withFunds)
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
        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): [Type]
        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the 
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): [Type]
        /// Composes a Strategy of the given type with the provided funds
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
        /// Returns the type of Vaults that this Strategy instance can handle
        access(all) view fun getSupportedCollateralTypes(): [Type]
        /// Returns whether the provided Vault type is supported by this Strategy instance
        access(all) view fun isSupportedCollateralType(_ type: Type): Bool
        /// Returns the balance of the given token available for withdrawal. Note that this may be an estimate due to
        /// the lack of guarantees inherent to DeFiBlocks Sources
        access(all) fun availableBalance(ofToken: Type): UFix64
        /// Deposits up to the balance of the referenced Vault into this Strategy
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        /// Withdraws from this Strategy and returns the resulting Vault of the requested token Type
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            post {
                result.getType() == ofToken: "Invalid Vault returns - requests \(ofToken.identifier) but returned \(result.getType().identifier)"
            }
        }
    }

    access(all) resource StrategyFactory {
        /// The strategies this factory can build
        access(self) let builders: {Type: {StrategyBuilder}}

        init() {
            self.builders = {}
        }

        access(all) view fun getSupportedStrategies(): [Type] {
            return self.builders.keys
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

    /* --- INTERNAL METHODS --- */

    access(account) view fun _borrowFactory(): &StrategyFactory {
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
