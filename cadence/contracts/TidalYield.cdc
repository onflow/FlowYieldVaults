import "FungibleToken"
import "Burner"
import "ViewResolver"

import "DFB"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract TidalYield {

    /// Canonical StoragePath for where TideManager should be stored
    access(all) let TideManagerStoragePath: StoragePath
    /// Canonical PublicPath for where TideManager Capability should be published
    access(all) let TideManagerPublicPath: PublicPath
    /// Canonical StoragePath for where StrategyFactory should be stored
    access(all) let FactoryStoragePath: StoragePath
    /// Canonical PublicPath for where StrategyFactory Capability should be published
    access(all) let FactoryPublicPath: PublicPath

    access(all) event CreatedTide(id: UInt64, idType: String, uuid: UInt64, initialAmount: UFix64, creator: Address?)
    access(all) event DepositedToTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, fromUUID: UInt64)
    access(all) event WithdrawnFromTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, toUUID: UInt64)
    access(all) event AddedToManager(id: UInt64, idType: String, owner: Address?, managerUUID: UInt64)
    access(all) event BurnedTide(id: UInt64, idType: String, remainingBalance: UFix64)

    /* --- PUBLIC METHODS --- */

    access(all) view fun getSupportedStrategies(): [Type] {
        return self._borrowFactory().getSupportedStrategies()
    }
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
        return self._borrowFactory().getSupportedInitializationVaults(forStrategy: forStrategy)
    }
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
        return self._borrowFactory().getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith)
    }
    access(all) fun createStrategy(type: Type, withFunds: @{FungibleToken.Vault}): {Strategy} {
        return self._borrowFactory().createStrategy(type, withFunds: <-withFunds)
    }
    access(all) fun createStrategyFactory(): @StrategyFactory {
        return <- create StrategyFactory()
    }
    access(all) fun createTideManager(): @TideManager {
        return <-create TideManager()
    }

    /* --- CONSTRUCTS --- */

    /// A Strategy is meant to encapsulate the Sink/Source entrypoints allowing for flows into and out of composed
    /// DeFiBlocks components. These compositions are intended to capitalize on some yield-bearing opportunity so that
    /// a Strategy bears yield on that which is deposited into it, albeit not without some risk. A Strategy then can be
    /// thought of as the top-level of a nesting of DeFiBlocks connectors & adapters where one can deposit & withdraw
    /// funds into the composed DeFi workflows
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyComposer.
    access(all) struct interface Strategy : DFB.IdentifiableStruct {
        /// Returns the type of Vaults that this Strategy instance can handle
        access(all) view fun getSupportedCollateralTypes(): {Type: Bool}
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

    /// A StrategyComposer is responsible for stacking DeFiBlocks connectors in a manner that composes a final Strategy.
    /// Since DeFiBlock Sink/Source only support single assets and some Strategies may be multi-asset, we deal with
    /// building a Strategy distinctly from encapsulating the top-level DFB connectors acting as entrypoints in to the
    /// composed DeFiBlocks infrastructure.
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyComposer.
    access(all) struct interface StrategyComposer {
        /// Returns the Types of Strategies composed by this StrategyComposer
        access(all) view fun getComposedStrategyTypes(): {Type: Bool}
        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool}
        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the 
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool}
        /// Composes a Strategy of the given type with the provided funds
        access(all) fun createStrategy(_ type: Type, withFunds: @{FungibleToken.Vault}, params: {String: AnyStruct}): {Strategy} {
            pre {
                self.getComposedStrategyTypes()[type] == true:
                "Strategy \(type.identifier) is unsupported by StrategyComposer \(self.getType().identifier)"
            }
        }
    }

    access(all) resource StrategyFactory {
        /// The strategies this factory can build
        access(self) let composers: {Type: {StrategyComposer}}

        init() {
            self.composers = {}
        }
        access(all) view fun getSupportedStrategies(): [Type] {
            return self.composers.keys
        }
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return self.composers[forStrategy]?.getSupportedInitializationVaults(forStrategy: forStrategy) ?? {}
        }
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return self.composers[forStrategy]?.getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith) ?? {}
        }
        access(all) fun createStrategy(_ type: Type, withFunds: @{FungibleToken.Vault}): {Strategy} {
            pre {
                self.composers[type] != nil: "Strategy \(type.identifier) is unsupported"
            }
            return self.composers[type]!.createStrategy(type, withFunds: <-withFunds, params: {}) // TODO: decide on params inclusion or not
        }
        access(Mutate) fun setStrategyComposer(_ strategy: Type, builder: {StrategyComposer}) {
            self.composers[strategy] = builder
        }
        access(Mutate) fun removeStrategy(_ strategy: Type): Bool {
            return self.composers.remove(key: strategy) != nil
        }
    }

    access(all) resource Tide : Burner.Burnable, FungibleToken.Receiver, ViewResolver.Resolver {
        access(contract) let uniqueID: DFB.UniqueIdentifier
        access(self) let vaultType: Type
        access(self) let strategy: {Strategy}

        init(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            // pre {
            //     TidalStrategies.isSupportedCollateralType(withVault.getType(), forStrategy: strategyNumber) == true:
            //     "Provided vault of type \(withVault.getType().identifier) is unsupported collateral Type for strategy \(strategyNumber)"
            // }
            self.uniqueID = DFB.UniqueIdentifier()
            self.vaultType = withVault.getType()
            self.strategy = TidalYield.createStrategy(type: strategyType, withFunds: <-withVault)
            assert(self.strategy.isSupportedCollateralType(self.vaultType), message: "TODO")
        }

        access(all) view fun id(): UInt64 {
            return self.uniqueID.id
        }

        access(all) fun getTideBalance(): UFix64 {
            return self.strategy.availableBalance(ofToken: self.vaultType)
        }

        access(contract) fun burnCallback() {
            emit BurnedTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, remainingBalance: self.getTideBalance())
        }

        access(all) view fun getViews(): [Type] {
            return []
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return nil
        }

        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                self.isSupportedVaultType(type: from.getType()):
                "Deposited vault of type \(from.getType().identifier) is not supported by this Tide"
            }
            emit DepositedToTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: from.balance, owner: self.owner?.address, fromUUID: from.uuid)
            self.strategy.deposit(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            assert(from.balance == 0.0, message: "TODO")
            Burner.burn(<-from)
        }

        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return self.strategy.getSupportedCollateralTypes()
        }

        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return self.getSupportedVaultTypes()[type] ?? false
        }

        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
            post {
                result.balance == amount: "TODO"
            }
            let available = self.strategy.availableBalance(ofToken: self.vaultType)
            assert(
                amount <= available,
                message: "Requested amount \(amount) is greater than withdrawable balance of \(available)"
            )
            let res <- self.strategy.withdraw(maxAmount: amount, ofToken: self.vaultType)
            emit WithdrawnFromTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: amount, owner: self.owner?.address, toUUID: res.uuid)
            return <- res
        }
    }

    access(all) entitlement Owner

    access(all) resource TideManager : ViewResolver.ResolverCollection {
        access(self) let tides: @{UInt64: Tide}

        init() {
            self.tides <- {}
        }

        access(all) view fun borrowTide(id: UInt64): &Tide? {
            return &self.tides[id]
        }

        access(all) view fun borrowViewResolver(id: UInt64): &{ViewResolver.Resolver}? {
            return &self.tides[id]
        }

        access(all) view fun getIDs(): [UInt64] {
            return self.tides.keys
        }

        access(all) view fun getNumberOfTides(): Int {
            return self.tides.length
        }

        access(all) fun createTide(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            let balance = withVault.balance
            let tide <-create Tide(strategyType: strategyType, withVault: <-withVault) // TODO: fix init

            emit CreatedTide(id: tide.uniqueID.id, idType: tide.uniqueID.getType().identifier, uuid: tide.uuid, initialAmount: balance, creator: self.owner?.address)

            self.addTide(<-tide)
        }

        access(all) fun addTide(_ tide: @Tide) {
            pre {
                self.tides[tide.uniqueID.id] == nil:
                "Collision with Tide ID \(tide.uniqueID.id) - a Tide with this ID already exists"
            }
            emit AddedToManager(id: tide.uniqueID.id, idType: tide.uniqueID.getType().identifier, owner: self.owner?.address, managerUUID: self.uuid)
            self.tides[tide.uniqueID.id] <-! tide
        }

        access(all) fun depositToTide(_ id: UInt64, from: @{FungibleToken.Vault}) {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as &Tide?)!
            tide.deposit(from: <-from)
        }

        access(Owner) fun withdrawTide(id: UInt64): @Tide {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            return <- self.tides.remove(key: id)!
        }

        access(Owner) fun withdrawFromTide(_ id: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as auth(FungibleToken.Withdraw) &Tide?)!
            return <- tide.withdraw(amount: amount)
        }

        access(Owner) fun closeTide(_ id: UInt64): @{FungibleToken.Vault} {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide <- self.withdrawTide(id: id)
            let res <- tide.withdraw(amount: tide.getTideBalance())
            Burner.burn(<-tide)
            return <-res
        }
    }

    /* --- INTERNAL METHODS --- */

    access(self) view fun _borrowFactory(): &StrategyFactory {
        return self.account.storage.borrow<&StrategyFactory>(from: self.FactoryStoragePath)
            ?? panic("Could not borrow reference to StrategyFactory from \(self.FactoryStoragePath)")
    }

    init() {
        var pathIdentifier = "TidalYieldTideManager_\(self.account.address)"
        self.TideManagerStoragePath = StoragePath(identifier: pathIdentifier)!
        self.TideManagerPublicPath = PublicPath(identifier: pathIdentifier)!

        pathIdentifier = "TidalYieldStrategyFactory_\(self.account.address)"
        self.FactoryStoragePath = StoragePath(identifier: pathIdentifier)!
        self.FactoryPublicPath = PublicPath(identifier: pathIdentifier)!

        // configure a StrategyFactory in storage and publish a public Capability
        self.account.storage.save(<-create StrategyFactory(), to: self.FactoryStoragePath)
        let cap = self.account.capabilities.storage.issue<&StrategyFactory>(self.FactoryStoragePath)
        self.account.capabilities.publish(cap, at: self.FactoryPublicPath)
    }
}
