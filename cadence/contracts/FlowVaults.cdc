// standards
import "FungibleToken"
import "Burner"
import "ViewResolver"
// DeFiActions
import "DeFiActions"
import "FlowVaultsClosedBeta"

/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract FlowVaults {

    /* --- FIELDS --- */

    /// Canonical StoragePath for where YieldVaultManager should be stored
    access(all) let YieldVaultManagerStoragePath: StoragePath
    /// Canonical PublicPath for where YieldVaultManager Capability should be published
    access(all) let YieldVaultManagerPublicPath: PublicPath
    /// Canonical StoragePath for where StrategyFactory should be stored
    access(all) let FactoryStoragePath: StoragePath
    /// Canonical PublicPath for where StrategyFactory Capability should be published
    access(all) let FactoryPublicPath: PublicPath

    /* --- EVENTS --- */

    access(all) event CreatedYieldVault(id: UInt64, uuid: UInt64, strategyType: String, tokenType: String, initialAmount: UFix64, creator: Address?)
    access(all) event DepositedToYieldVault(id: UInt64, tokenType: String, amount: UFix64, owner: Address?, fromUUID: UInt64)
    access(all) event WithdrawnFromYieldVault(id: UInt64, tokenType: String, amount: UFix64, owner: Address?, toUUID: UInt64)
    access(all) event AddedToManager(id: UInt64, owner: Address?, managerUUID: UInt64, tokenType: String)
    access(all) event BurnedYieldVault(id: UInt64, strategyType: String, tokenType: String, remainingBalance: UFix64)

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

    /// YieldVault
    ///
    /// A YieldVault is a resource enabling the management of a composed Strategy
    ///
    access(all) resource YieldVault : Burner.Burnable, FungibleToken.Receiver, ViewResolver.Resolver {
        /// The UniqueIdentifier that identifies all related DeFiActions connectors used in the encapsulated Strategy
        access(contract) let uniqueID: DeFiActions.UniqueIdentifier
        /// The type of Vault this YieldVault can receive as a deposit and provides as a withdrawal
        access(self) let vaultType: Type
        /// The Strategy granting top-level access to the yield-bearing DeFiActions stack
        access(self) var strategy: @{Strategy}?

        init(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            self.uniqueID = DeFiActions.createUniqueIdentifier()
            self.vaultType = withVault.getType()
            let _strategy <- FlowVaults.createStrategy(
                    type: strategyType,
                    uniqueID: self.uniqueID,
                    withFunds: <-withVault
                )
            assert(_strategy.isSupportedCollateralType(self.vaultType),
                message: "Vault type \(self.vaultType.identifier) is not supported by Strategy \(strategyType.identifier)")
            self.strategy <-_strategy
        }

        /// Returns the YieldVault's ID as defined by it's DeFiActions.UniqueIdentifier.id
        access(all) view fun id(): UInt64 {
            return self.uniqueID.id
        }
        /// Returns the balance of the YieldVault's vaultType available via the encapsulated Strategy
        access(all) fun getYieldVaultBalance(): UFix64 {
            return self._borrowStrategy().availableBalance(ofToken: self.vaultType)
        }
        /// Burner.Burnable conformance - emits the BurnedYieldVault event when burned
        access(contract) fun burnCallback() {
            emit BurnedYieldVault(
                id: self.uniqueID.id,
                strategyType: self.strategy.getType().identifier,
                tokenType: self.getType().identifier,
                remainingBalance: self.getYieldVaultBalance()
            )
            let _strategy <- self.strategy <- nil
            // Force unwrap to ensure burnCallback is called on the Strategy
            Burner.burn(<-_strategy!)
        }
        /// TODO: FlowVaults specific views
        access(all) view fun getViews(): [Type] {
            return []
        }
        /// TODO: FlowVaults specific view resolution
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return nil
        }
        /// Deposits the provided Vault to the Strategy
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                self.isSupportedVaultType(type: from.getType()):
                "Deposited vault of type \(from.getType().identifier) is not supported by this YieldVault"
            }
            let amount = from.balance
            emit DepositedToYieldVault(id: self.uniqueID.id, tokenType: from.getType().identifier, amount: from.balance, owner: self.owner?.address, fromUUID: from.uuid)
            self._borrowStrategy().deposit(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            assert(
                from.balance == 0.0,
                message: "Deposit amount \(amount) of \(self.vaultType.identifier) could not be deposited to YieldVault \(self.id())"
            )
            Burner.burn(<-from)
        }
        /// Returns the Vaults types supported by this YieldVault as a mapping associated with their current support status
        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return self._borrowStrategy().getSupportedCollateralTypes()
        }
        /// Returns whether the given Vault type is supported by this YieldVault
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

            emit WithdrawnFromYieldVault(id: self.uniqueID.id, tokenType: res.getType().identifier, amount: amount, owner: self.owner?.address, toUUID: res.uuid)

            return <- res
        }
        /// Returns an authorized reference to the encapsulated Strategy
        access(self) view fun _borrowStrategy(): auth(FungibleToken.Withdraw) &{Strategy} {
            return &self.strategy as auth(FungibleToken.Withdraw) &{Strategy}?
                ?? panic("Unknown error - could not borrow Strategy for YieldVault #\(self.id())")
        }
    }

    /// YieldVaultManager
    ///
    /// A YieldVaultManager encapsulates nested YieldVault resources. Through a YieldVaultManager, one can create, manage, and close
    /// out inner YieldVault resources.
    ///
    access(all) resource YieldVaultManager : ViewResolver.ResolverCollection {
        /// The open YieldVaults managed by this YieldVaultManager
        access(self) let yieldVaults: @{UInt64: YieldVault}

        init() {
            self.yieldVaults <- {}
        }

        /// Borrows the unauthorized YieldVault with the given id, returning `nil` if none exists
        access(all) view fun borrowYieldVault(id: UInt64): &YieldVault? {
            return &self.yieldVaults[id]
        }
        /// Borrows the YieldVault with the given ID as a ViewResolver.Resolver, returning `nil` if none exists
        access(all) view fun borrowViewResolver(id: UInt64): &{ViewResolver.Resolver}? {
            return &self.yieldVaults[id]
        }
        /// Returns the YieldVault IDs managed by this YieldVaultManager
        access(all) view fun getIDs(): [UInt64] {
            return self.yieldVaults.keys
        }
        /// Returns the number of open YieldVaults currently managed by this YieldVaultManager
        access(all) view fun getNumberOfYieldVaults(): Int {
            return self.yieldVaults.length
        }
        /// Creates a new YieldVault executing the specified Strategy with the provided funds.
        /// Returns the newly created YieldVault ID.
        access(all) fun createYieldVault(
            betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge,
            strategyType: Type,
            withVault: @{FungibleToken.Vault}
        ): UInt64 {
            pre {
                FlowVaultsClosedBeta.validateBeta(self.owner?.address!, betaRef):
                "Invalid Beta Ref"
            }
            let balance = withVault.balance
            let type = withVault.getType()
            let yieldVault <-create YieldVault(strategyType: strategyType, withVault: <-withVault)
            let newID = yieldVault.uniqueID.id

            emit CreatedYieldVault(
                id: newID,
                uuid: yieldVault.uuid,
                strategyType: strategyType.identifier,
                tokenType: type.identifier,
                initialAmount: balance,
                creator: self.owner?.address
            )

            self.addYieldVault(betaRef: betaRef, <-yieldVault)

            return newID
        }
        /// Adds an open YieldVault to this YieldVaultManager resource. This effectively transfers ownership of the newly added
        /// YieldVault to the owner of this YieldVaultManager
        access(all) fun addYieldVault(betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge, _ yieldVault: @YieldVault) {
            pre {
                self.yieldVaults[yieldVault.uniqueID.id] == nil:
                "Collision with YieldVault ID \(yieldVault.uniqueID.id) - a YieldVault with this ID already exists"

                FlowVaultsClosedBeta.validateBeta(self.owner?.address!, betaRef):
                "Invalid Beta Ref"
            }
            emit AddedToManager(id: yieldVault.uniqueID.id, owner: self.owner?.address, managerUUID: self.uuid, tokenType: yieldVault.getType().identifier)
            self.yieldVaults[yieldVault.uniqueID.id] <-! yieldVault
        }
        /// Deposits additional funds to the specified YieldVault, reverting if none exists with the provided ID
        access(all) fun depositToYieldVault(betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge, _ id: UInt64, from: @{FungibleToken.Vault}) {
            pre {
                self.yieldVaults[id] != nil:
                "No YieldVault with ID \(id) found"

                FlowVaultsClosedBeta.validateBeta(self.owner?.address!, betaRef):
                "Invalid Beta Ref"
            }
            let yieldVault = (&self.yieldVaults[id] as &YieldVault?)!
            yieldVault.deposit(from: <-from)
        }
        access(self) fun _withdrawYieldVault(id: UInt64): @ YieldVault {
            pre {
                self.yieldVaults[id] != nil:
                "No YieldVault with ID \(id) found"
            }
            return <- self.yieldVaults.remove(key: id)!
        }
        /// Withdraws the specified YieldVault, reverting if none exists with the provided ID
        access(FungibleToken.Withdraw) fun withdrawYieldVault(betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge, id: UInt64): @ YieldVault {
            pre {
                self.yieldVaults[id] != nil:
                "No YieldVault with ID \(id) found"

                FlowVaultsClosedBeta.validateBeta(self.owner?.address!, betaRef):
                "Invalid Beta Ref"
            }
            return <- self._withdrawYieldVault(id: id)
        }
        /// Withdraws funds from the specified YieldVault in the given amount. The resulting Vault Type will be whatever
        /// denomination is supported by the YieldVault, so callers should examine the YieldVault to know the resulting Vault to
        /// expect
        access(FungibleToken.Withdraw) fun withdrawFromYieldVault(_ id: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.yieldVaults[id] != nil:
                "No YieldVault with ID \(id) found"
            }
            let yieldVault = (&self.yieldVaults[id] as auth(FungibleToken.Withdraw) &YieldVault?)!
            return <- yieldVault.withdraw(amount: amount)
        }
        /// Withdraws and returns all available funds from the specified YieldVault, destroying the YieldVault and access to any
        /// Strategy-related wiring with it
        access(FungibleToken.Withdraw) fun closeYieldVault(_ id: UInt64): @{FungibleToken.Vault} {
            pre {
                self.yieldVaults[id] != nil:
                "No YieldVault with ID \(id) found"
            }

            let yieldVault <- self._withdrawYieldVault(id: id)
            let res <- yieldVault.withdraw(amount: yieldVault.getYieldVaultBalance())
            Burner.burn(<-yieldVault)
            return <-res
        }
    }

    /* --- PUBLIC METHODS --- */

    /// Returns the Types of Strategies that can be used in YieldVaults
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
    /// Creates a YieldVaultManager used to create and manage YieldVaults
    access(all) fun createYieldVaultManager(betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge): @ YieldVaultManager {
        return <-create YieldVaultManager()
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
        var pathIdentifier = "FlowVaultsYieldVaultManager_\(self.account.address)"
        self.YieldVaultManagerStoragePath = StoragePath(identifier: pathIdentifier)!
        self.YieldVaultManagerPublicPath = PublicPath(identifier: pathIdentifier)!

        pathIdentifier = "FlowVaultsStrategyFactory_\(self.account.address)"
        self.FactoryStoragePath = StoragePath(identifier: pathIdentifier)!
        self.FactoryPublicPath = PublicPath(identifier: pathIdentifier)!

        // configure a StrategyFactory in storage and publish a public Capability
        self.account.storage.save(<-create StrategyFactory(), to: self.FactoryStoragePath)
        let cap = self.account.capabilities.storage.issue<&StrategyFactory>(self.FactoryStoragePath)
        self.account.capabilities.publish(cap, at: self.FactoryPublicPath)
    }
}