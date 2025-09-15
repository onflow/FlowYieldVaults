// standards
import "FungibleToken"
import "Burner"
import "ViewResolver"
// DeFiActions
import "DeFiActions"

/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract TidalYield {

    /* --- FIELDS --- */

    /// Canonical StoragePath for where TideManager should be stored
    access(all) let TideManagerStoragePath: StoragePath
    /// Canonical PublicPath for where TideManager Capability should be published
    access(all) let TideManagerPublicPath: PublicPath
    /// Canonical StoragePath for where StrategyFactory should be stored
    access(all) let FactoryStoragePath: StoragePath
    /// Canonical PublicPath for where StrategyFactory Capability should be published
    access(all) let FactoryPublicPath: PublicPath

    /* --- EVENTS --- */

    access(all) event CreatedTide(id: UInt64, uuid: UInt64, strategyType: String, tokenType: String, initialAmount: UFix64, creator: Address?)
    access(all) event DepositedToTide(id: UInt64, tokenType: String, amount: UFix64, owner: Address?, fromUUID: UInt64)
    access(all) event WithdrawnFromTide(id: UInt64, tokenType: String, amount: UFix64, owner: Address?, toUUID: UInt64)
    access(all) event AddedToManager(id: UInt64, owner: Address?, managerUUID: UInt64, tokenType: String)
    access(all) event BurnedTide(id: UInt64, strategyType: String, tokenType: String, remainingBalance: UFix64)

    /* --- CONSTRUCTS --- */

    /// Strategy
    ///
    /// A Strategy is meant to encapsulate the Sink/Source entrypoints allowing for flows into and out of stacked
    /// DeFiActions components. These compositions are intended to capitalize on some yield-bearing opportunity so that
    /// a Strategy bears yield on that which is deposited into it, albeit not without some risk. A Strategy then can be
    /// thought of as the top-level of a nesting of DeFiActions connectors & adapters where one can deposit & withdraw
    /// funds into the composed DeFi workflows.
    ///
    /// While two types of strategies may not highly differ with respect to their fields, the stacking of DeFiActions
    /// components & connections they provide access to likely do. This difference in wiring is why the Strategy is a
    /// resource - because the Type and uniqueness of composition of a given Strategy must be preserved as that is its
    /// distinguishing factor. These qualities are preserved by restricting the party who can construct it, which for
    /// resources is within the contract that defines it.
    ///
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyComposer.
    access(all) resource interface Strategy : DeFiActions.IdentifiableResource, Burner.Burnable {
        /// Returns the type of Vaults that this Strategy instance can handle
        access(all) view fun getSupportedCollateralTypes(): {Type: Bool}
        /// Returns whether the provided Vault type is supported by this Strategy instance
        access(all) view fun isSupportedCollateralType(_ type: Type): Bool {
            return self.getSupportedCollateralTypes()[type] ?? false
        }
        /// Returns the balance of the given token available for withdrawal. Note that this may be an estimate due to
        /// the lack of guarantees inherent to DeFiActions Sources
        access(all) fun availableBalance(ofToken: Type): UFix64
        /// Deposits up to the balance of the referenced Vault into this Strategy
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                self.isSupportedCollateralType(from.getType()):
                "Cannot deposit Vault \(from.getType().identifier) to Strategy \(self.getType().identifier) - unsupported deposit type"
            }
        }
        /// Withdraws from this Strategy and returns the resulting Vault of the requested token Type
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            post {
                result.getType() == ofToken:
                "Invalid Vault returns - requests \(ofToken.identifier) but returned \(result.getType().identifier)"
            }
        }
    }

    /// StrategyComposer
    ///
    /// A StrategyComposer is responsible for stacking DeFiActions connectors in a manner that composes a final Strategy.
    /// Since DeFiActions Sink/Source only support single assets and some Strategies may be multi-asset, we deal with
    /// building a Strategy distinctly from encapsulating the top-level DFA connectors acting as entrypoints in to the
    /// DeFiActions stack.
    ///
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyComposer.
    access(all) resource interface StrategyComposer {
        /// Returns the Types of Strategies composed by this StrategyComposer
        access(all) view fun getComposedStrategyTypes(): {Type: Bool}
        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool}
        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool}
        /// Composes a Strategy of the given type with the provided funds
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{Strategy} {
            pre {
                self.getSupportedInitializationVaults(forStrategy: type)[withFunds.getType()] == true:
                "Cannot initialize Strategy \(type.identifier) with Vault \(withFunds.getType().identifier) - unsupported initialization Vault"
                self.getComposedStrategyTypes()[type] == true:
                "Strategy \(type.identifier) is unsupported by StrategyComposer \(self.getType().identifier)"
            }
        }
    }

    /// StrategyFactory
    ///
    /// This resource enables the management of StrategyComposers and the construction of the Strategies they compose.
    ///
    access(all) resource StrategyFactory {
        /// A mapping of StrategyComposers indexed on the related Strategies they can compose
        access(self) let composers: @{Type: {StrategyComposer}}

        init() {
            self.composers <- {}
        }

        /// Returns the Strategy types that can be produced by this StrategyFactory
        access(all) view fun getSupportedStrategies(): [Type] {
            return self.composers.keys
        }
        /// Returns the Vaults that can be used to initialize a Strategy of the given Type
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return self.composers[forStrategy]?.getSupportedInitializationVaults(forStrategy: forStrategy) ?? {}
        }
        /// Returns the Vaults that can be deposited to a Strategy initialized with the provided Type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return self.composers[forStrategy]
                ?.getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith)
                ?? {}
        }
        /// Initializes a new Strategy of the given type with the provided Vault, identifying all associated DeFiActions
        /// components by the provided UniqueIdentifier
        access(all)
        fun createStrategy(_ type: Type, uniqueID: DeFiActions.UniqueIdentifier, withFunds: @{FungibleToken.Vault}): @{Strategy} {
            pre {
                self.composers[type] != nil: "Strategy \(type.identifier) is unsupported"
            }
            post {
                result.getType() == type:
                "Invalid Strategy returned - expected \(type.identifier) but returned \(result.getType().identifier)"
            }
            return <- self._borrowComposer(forStrategy: type)
                .createStrategy(type, uniqueID: uniqueID, withFunds: <-withFunds)
        }
        /// Sets the provided Strategy and Composer association in the StrategyFactory
        access(Mutate) fun addStrategyComposer(_ strategy: Type, composer: @{StrategyComposer}) {
            pre {
                strategy.isSubtype(of: Type<@{Strategy}>()):
                "Invalid Strategy Type \(strategy.identifier) - provided Type does not implement the Strategy interface"
                composer.getComposedStrategyTypes()[strategy] == true:
                "Strategy \(strategy.identifier) cannot be composed by StrategyComposer \(composer.getType().identifier)"
            }
            let old <- self.composers[strategy] <- composer
            Burner.burn(<-old)
        }
        /// Removes the Strategy from this StrategyFactory and returns whether the value existed or not
        access(Mutate) fun removeStrategy(_ strategy: Type): Bool {
            if let removed <- self.composers.remove(key: strategy) {
                Burner.burn(<-removed)
                return true
            }
            return false
        }
        /// Returns a reference to the StrategyComposer for the requested Strategy type, reverting if none exists
        access(self) view fun _borrowComposer(forStrategy: Type): &{StrategyComposer} {
            return &self.composers[forStrategy] as &{StrategyComposer}?
                ?? panic("Could not borrow StrategyComposer for Strategy \(forStrategy.identifier)")
        }
    }

    /// StrategyComposerIssuer
    ///
    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Contracts defining Strategies that do not require
    /// such protections may wish to expose Strategy creation publicly via public Capabilities.
    access(all) resource interface StrategyComposerIssuer {
        /// Returns the StrategyComposer types supported by this issuer
        access(all) view fun getSupportedComposers(): {Type: Bool}
        /// Returns the requested StrategyComposer. If the requested type is unsupported, a revert should be expected
        access(all) fun issueComposer(_ type: Type): @{StrategyComposer} {
            post {
                result.getType() == type:
                "Invalid StrategyComposer returned - requested \(type.identifier) but returned \(result.getType().identifier)"
            }
        }
    }

    /// Tide
    ///
    /// A Tide is a resource enabling the management of a composed Strategy
    ///
    access(all) resource Tide : Burner.Burnable, FungibleToken.Receiver, ViewResolver.Resolver {
        /// The UniqueIdentifier that identifies all related DeFiActions connectors used in the encapsulated Strategy
        access(contract) let uniqueID: DeFiActions.UniqueIdentifier
        /// The type of Vault this Tide can receive as a deposit and provides as a withdrawal
        access(self) let vaultType: Type
        /// The Strategy granting top-level access to the yield-bearing DeFiActions stack
        access(self) var strategy: @{Strategy}?

        init(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            self.uniqueID = DeFiActions.UniqueIdentifier()
            self.vaultType = withVault.getType()
            let _strategy <- TidalYield.createStrategy(
                    type: strategyType,
                    uniqueID: self.uniqueID,
                    withFunds: <-withVault
                )
            assert(_strategy.isSupportedCollateralType(self.vaultType),
                message: "Vault type \(self.vaultType.identifier) is not supported by Strategy \(strategyType.identifier)")
            self.strategy <-_strategy
        }

        /// Returns the Tide's ID as defined by it's DeFiActions.UniqueIdentifier.id
        access(all) view fun id(): UInt64 {
            return self.uniqueID.id
        }
        /// Returns the balance of the Tide's vaultType available via the encapsulated Strategy
        access(all) fun getTideBalance(): UFix64 {
            return self._borrowStrategy().availableBalance(ofToken: self.vaultType)
        }
        /// Burner.Burnable conformance - emits the BurnedTide event when burned
        access(contract) fun burnCallback() {
            emit BurnedTide(
                id: self.uniqueID.id,
                strategyType: self.strategy.getType().identifier,
                tokenType: self.getType().identifier,
                remainingBalance: self.getTideBalance()
            )
            let _strategy <- self.strategy <- nil
            Burner.burn(<-_strategy)
        }
        /// TODO: TidalYield specific views
        access(all) view fun getViews(): [Type] {
            return []
        }
        /// TODO: TidalYield specific view resolution
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return nil
        }
        /// Deposits the provided Vault to the Strategy
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                self.isSupportedVaultType(type: from.getType()):
                "Deposited vault of type \(from.getType().identifier) is not supported by this Tide"
            }
            let amount = from.balance
            emit DepositedToTide(id: self.uniqueID.id, tokenType: from.getType().identifier, amount: from.balance, owner: self.owner?.address, fromUUID: from.uuid)
            self._borrowStrategy().deposit(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            assert(
                from.balance == 0.0,
                message: "Deposit amount \(amount) of \(self.vaultType.identifier) could not be deposited to Tide \(self.id())"
            )
            Burner.burn(<-from)
        }
        /// Returns the Vaults types supported by this Tide as a mapping associated with their current support status
        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return self._borrowStrategy().getSupportedCollateralTypes()
        }
        /// Returns whether the given Vault type is supported by this Tide
        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return self.getSupportedVaultTypes()[type] ?? false
        }
        /// Withdraws the requested amount from the Strategy
        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
            post {
                result.balance == amount:
                "Invalid Vault balance returned - requested \(amount) but returned \(result.balance)"
                self.vaultType == result.getType():
                "Invalid Vault returned - expected \(self.vaultType.identifier) but returned \(result.getType().identifier)"
            }
            let available = self._borrowStrategy().availableBalance(ofToken: self.vaultType)
            assert(amount <= available,
                message: "Requested amount \(amount) is greater than withdrawable balance of \(available)")

            let res <- self._borrowStrategy().withdraw(maxAmount: amount, ofToken: self.vaultType)

            emit WithdrawnFromTide(id: self.uniqueID.id, tokenType: res.getType().identifier, amount: amount, owner: self.owner?.address, toUUID: res.uuid)

            return <- res
        }
        /// Returns an authorized reference to the encapsulated Strategy
        access(self) view fun _borrowStrategy(): auth(FungibleToken.Withdraw) &{Strategy} {
            return &self.strategy as auth(FungibleToken.Withdraw) &{Strategy}?
                ?? panic("Unknown error - could not borrow Strategy for Tide #\(self.id())")
        }
    }

    /// TideManager
    ///
    /// A TideManager encapsulates nested Tide resources. Through a TideManager, one can create, manage, and close
    /// out inner Tide resources.
    ///
    access(all) resource TideManager : ViewResolver.ResolverCollection {
        /// The open Tides managed by this TideManager
        access(self) let tides: @{UInt64: Tide}

        init() {
            self.tides <- {}
        }

        /// Borrows the unauthorized Tide with the given id, returning `nil` if none exists
        access(all) view fun borrowTide(id: UInt64): &Tide? {
            return &self.tides[id]
        }
        /// Borrows the Tide with the given ID as a ViewResolver.Resolver, returning `nil` if none exists
        access(all) view fun borrowViewResolver(id: UInt64): &{ViewResolver.Resolver}? {
            return &self.tides[id]
        }
        /// Returns the Tide IDs managed by this TideManager
        access(all) view fun getIDs(): [UInt64] {
            return self.tides.keys
        }
        /// Returns the number of open Tides currently managed by this TideManager
        access(all) view fun getNumberOfTides(): Int {
            return self.tides.length
        }
        /// Creates a new Tide executing the specified Strategy with the provided funds
        access(all) fun createTide(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            let balance = withVault.balance
            let type = withVault.getType()
            let tide <-create Tide(strategyType: strategyType, withVault: <-withVault)

            emit CreatedTide(
                id: tide.uniqueID.id,
                uuid: tide.uuid,
                strategyType: strategyType.identifier,
                tokenType: type.identifier,
                initialAmount: balance,
                creator: self.owner?.address
            )

            self.addTide(<-tide)
        }
        /// Adds an open Tide to this TideManager resource. This effectively transfers ownership of the newly added
        /// Tide to the owner of this TideManager
        access(all) fun addTide(_ tide: @Tide) {
            pre {
                self.tides[tide.uniqueID.id] == nil:
                "Collision with Tide ID \(tide.uniqueID.id) - a Tide with this ID already exists"
            }
            emit AddedToManager(id: tide.uniqueID.id, owner: self.owner?.address, managerUUID: self.uuid, tokenType: tide.getType().identifier)
            self.tides[tide.uniqueID.id] <-! tide
        }
        /// Deposits additional funds to the specified Tide, reverting if none exists with the provided ID
        access(all) fun depositToTide(_ id: UInt64, from: @{FungibleToken.Vault}) {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as &Tide?)!
            tide.deposit(from: <-from)
        }
        /// Withdraws the specified Tide, reverting if none exists with the provided ID
        access(FungibleToken.Withdraw) fun withdrawTide(id: UInt64): @Tide {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            return <- self.tides.remove(key: id)!
        }
        /// Withdraws funds from the specified Tide in the given amount. The resulting Vault Type will be whatever
        /// denomination is supported by the Tide, so callers should examine the Tide to know the resulting Vault to
        /// expect
        access(FungibleToken.Withdraw) fun withdrawFromTide(_ id: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as auth(FungibleToken.Withdraw) &Tide?)!
            return <- tide.withdraw(amount: amount)
        }
        /// Withdraws and returns all available funds from the specified Tide, destroying the Tide and access to any
        /// Strategy-related wiring with it
        access(FungibleToken.Withdraw) fun closeTide(_ id: UInt64): @{FungibleToken.Vault} {
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

    /* --- PUBLIC METHODS --- */

    /// Returns the Types of Strategies that can be used in Tides
    access(all) view fun getSupportedStrategies(): [Type] {
        return self._borrowFactory().getSupportedStrategies()
    }
    /// Returns the Vault types which can be used to initialize a given Strategy
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
        return self._borrowFactory().getSupportedInitializationVaults(forStrategy: forStrategy)
    }
    /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
    /// provided Vault type
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
        return self._borrowFactory().getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith)
    }
    /// Creates a Strategy of the requested Type using the provided Vault as an initial deposit
    access(all) fun createStrategy(type: Type, uniqueID: DeFiActions.UniqueIdentifier, withFunds: @{FungibleToken.Vault}): @{Strategy} {
        return <- self._borrowFactory().createStrategy(type, uniqueID: uniqueID, withFunds: <-withFunds)
    }
    /// Creates a TideManager used to create and manage Tides
    access(all) fun createTideManager(): @TideManager {
        return <-create TideManager()
    }
    /// Creates a StrategyFactory resource
    access(all) fun createStrategyFactory(): @StrategyFactory {
        return <- create StrategyFactory()
    }

    /* --- INTERNAL METHODS --- */

    /// Returns a reference to the StrategyFactory stored in this contract's account storage
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
