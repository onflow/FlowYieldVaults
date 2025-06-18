// standards
import "FungibleToken"
import "Burner"
import "ViewResolver"
// DeFiBlocks
import "DFB"

import "StrategyComposer"

/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract Tidal {

    /* --- FIELDS --- */

    /// Canonical StoragePath for where TideManager should be stored
    access(all) let TideManagerStoragePath: StoragePath
    /// Canonical PublicPath for where TideManager Capability should be published
    access(all) let TideManagerPublicPath: PublicPath
    /// Canonical StoragePath for the contract's Admin resource
    access(all) let AdminStoragePath: StoragePath

    /// The statuses for all added Strategy Types and whether they are currently enabled or not
    access(self) let strategyStatus: {Type: Bool}

    /* --- EVENTS --- */

    access(all) event CreatedTide(id: UInt64, idType: String, uuid: UInt64, initialAmount: UFix64, creator: Address?)
    access(all) event DepositedToTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, fromUUID: UInt64)
    access(all) event WithdrawnFromTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, toUUID: UInt64)
    access(all) event AddedToManager(id: UInt64, idType: String, owner: Address?, managerUUID: UInt64)
    access(all) event BurnedTide(id: UInt64, idType: String, remainingBalance: UFix64)

    /* --- PUBLIC METHODS --- */

    /// Creates a TideManager used to create and manage Tides
    access(all) fun createTideManager(): @TideManager {
        return <-create TideManager()
    }
    
    /// Returns the Strategy types and their relevant support status for new Tides
    access(all) view fun getSupportedStrategies(): {Type: Bool} {
        return self.strategyStatus
    }

    /// Returns the Vaults that can be used to initialize a Strategy of the given Type
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
        if self.strategyStatus[forStrategy] == nil {
            return {}
        }
        return self._borrowStrategyComposer(forType: forStrategy)
            ?.getSupportedInitializationVaults(forStrategy: forStrategy)
            ?? {}
    }

    /// Returns the Vaults that can be deposited to a Strategy initialized with the provided Type
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
        if self.strategyStatus[forStrategy] == nil {
            return {}
        }
        return self._borrowStrategyComposer(forType: forStrategy)
            ?.getSupportedInstanceVaults(forStrategy: forStrategy, initializedWith: initializedWith)
            ?? {}
    }

    /* --- CONSTRUCTS --- */

    /// Tide
    ///
    /// A Tide is a resource enabling the management of a composed Strategy
    ///
    access(all) resource Tide : Burner.Burnable, FungibleToken.Receiver, ViewResolver.Resolver {
        /// The UniqueIdentifier that identifies all related DeFiBlocks connectors used in the encapsulated Strategy
        access(contract) let uniqueID: DFB.UniqueIdentifier
        /// The type of Vault this Tide can receive as a deposit and provides as a withdrawal
        access(self) let vaultType: Type
        /// The Strategy granting top-level access to the yield-bearing DeFiBlocks stack
        access(self) var strategy: @{StrategyComposer.Strategy}?

        init(strategyType: Type, withVault: @{FungibleToken.Vault}) {
            self.uniqueID = DFB.UniqueIdentifier()
            self.vaultType = withVault.getType()
            let _strategy <- Tidal._createStrategy(
                    strategyType,
                    uniqueID: self.uniqueID,
                    withFunds: <-withVault
                )
            assert(_strategy.isSupportedCollateralType(self.vaultType),
                message: "Vault type \(self.vaultType.identifier) is not supported by Strategy \(strategyType.identifier)")
            self.strategy <-_strategy
        }

        /// Returns the Tide's ID as defined by it's DFB.UniqueIdentifier.id
        access(all) view fun id(): UInt64 {
            return self.uniqueID.id
        }
        /// Returns the balance of the Tide's vaultType available via the encapsulated Strategy
        access(all) fun getTideBalance(): UFix64 {
            return self._borrowStrategy().availableBalance(ofToken: self.vaultType)
        }
        /// Burner.Burnable conformance - emits the BurnedTide event when burned
        access(contract) fun burnCallback() {
            emit BurnedTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, remainingBalance: self.getTideBalance())
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
            emit DepositedToTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: from.balance, owner: self.owner?.address, fromUUID: from.uuid)
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

            emit WithdrawnFromTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: amount, owner: self.owner?.address, toUUID: res.uuid)

            return <- res
        }
        /// Returns an authorized reference to the encapsulated Strategy
        access(self) view fun _borrowStrategy(): auth(FungibleToken.Withdraw) &{StrategyComposer.Strategy} {
            return &self.strategy as auth(FungibleToken.Withdraw) &{StrategyComposer.Strategy}?
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
            let tide <-create Tide(strategyType: strategyType, withVault: <-withVault) // TODO: fix init

            emit CreatedTide(id: tide.uniqueID.id, idType: tide.uniqueID.getType().identifier, uuid: tide.uuid, initialAmount: balance, creator: self.owner?.address)

            self.addTide(<-tide)
        }
        /// Adds an open Tide to this TideManager resource. This effectively transfers ownership of the newly added
        /// Tide to the owner of this TideManager
        access(all) fun addTide(_ tide: @Tide) {
            pre {
                self.tides[tide.uniqueID.id] == nil:
                "Collision with Tide ID \(tide.uniqueID.id) - a Tide with this ID already exists"
            }
            emit AddedToManager(id: tide.uniqueID.id, idType: tide.uniqueID.getType().identifier, owner: self.owner?.address, managerUUID: self.uuid)
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

    // Admin-related entitlements
    access(all) entitlement Add
    access(all) entitlement Set
    access(all) entitlement Delete
    
    /// Admin
    ///
    access(all) resource Admin {
        /// Sets the provided Strategy and Composer association in the Tidal contract
        access(Add) fun addStrategy(_ strategy: Type, enable: Bool) {
            pre {
                strategy.isSubtype(of: Type<@{StrategyComposer.Strategy}>()):
                "Invalid Strategy Type \(strategy.identifier) - provided Type does not implement the Strategy interface"
                Tidal._borrowStrategyComposer(forType: strategy) != nil:
                "Invalid Strategy-defining contract for type \(strategy.identifier) - contract does not conform to StrategyComposer interface"
                Tidal._borrowStrategyComposer(forType: strategy)!.getComposedStrategyTypes()[strategy] == true:
                "Strategy \(strategy.identifier) cannot be composed by its defining StrategyComposer contract"
            }
            Tidal.strategyStatus[strategy] = enable
        }
        /// Sets the Strategy's status as enabled or disabled
        access(Set) fun setStrategyStatus(_ type: Type, enable: Bool) {
            pre {
                Tidal.strategyStatus[type] != nil: "Attempting to set status for an unsupported Strategy \(type.identifier)"
            }
            post {
                Tidal.strategyStatus[type] == enable:
                "Error when setting the status of Strategy \(type.identifier) to \(enable)"
            }
            Tidal.strategyStatus[type] = enable
        }
        /// Removes the Strategy from the Tidal contract and returns whether the value existed or not
        access(Delete) fun removeStrategy(_ strategy: Type): Bool {
            return Tidal.strategyStatus.remove(key: strategy) != nil
        }
    }

    /* --- INTERNAL METHODS --- */

    /// Creates a Strategy of the provided Type with the funds provided
    access(self) fun _createStrategy(
        _ type: Type,
        uniqueID: DFB.UniqueIdentifier,
        withFunds: @{FungibleToken.Vault}
    ): @{StrategyComposer.Strategy} {
        pre {
            type.isSubtype(of: Type<@{StrategyComposer.Strategy}>()):
            "Requested type \(type.identifier) is not a StrategyComposer.Strategy implementation"
            self.strategyStatus[type] == true:
            "Requested Strategy \(type.identifier) is unsupported by TidalYield"
        }
        let composer = self._borrowStrategyComposer(forType: type)
            ?? panic("Could not borrow StrategyComposer contract for Strategy \(type.identifier)")
        return <- composer.createStrategy(type, uniqueID: uniqueID, withFunds: <-withFunds)
    }

    /// Returns a reference to the StrategyComposer assuming the contract defines the Strategy Type
    access(self) view fun _borrowStrategyComposer(forType: Type): &{StrategyComposer}? {
        if !forType.isSubtype(of: Type<@{StrategyComposer.Strategy}>()) {
            return nil
        }
        return getAccount(forType.address!).contracts.borrow<&{StrategyComposer}>(name: forType.contractName!)
    }

    init() {
        let pathIdentifier = "TidalYieldTideManager_\(self.account.address)"
        self.TideManagerStoragePath = StoragePath(identifier: pathIdentifier)!
        self.TideManagerPublicPath = PublicPath(identifier: pathIdentifier)!
        self.AdminStoragePath = StoragePath(identifier: "TidalYieldAdmin_\(self.account.address)")!

        self.strategyStatus = {}

        self.account.storage.save(<-create Admin(), to: self.AdminStoragePath)
    }
}
