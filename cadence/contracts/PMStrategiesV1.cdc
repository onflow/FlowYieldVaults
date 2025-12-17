// standards
import "FungibleToken"
import "FlowToken"
import "EVM"
// DeFiActions
import "DeFiActionsUtils"
import "DeFiActions"
import "SwapConnectors"
import "FungibleTokenConnectors"
// amm integration
import "UniswapV3SwapConnectors"
import "ERC4626SwapConnectors"
import "ERC4626Utils"
// FlowYieldVaults platform
import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancers"
// scheduler
import "FlowTransactionScheduler"
import "FlowYieldVaultsSchedulerRegistry"
// vm bridge
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "FlowEVMBridge"
// live oracles
import "ERC4626PriceOracles"

/// PMStrategiesV1
///
/// This contract defines Strategies used in the FlowYieldVaults platform.
///
/// A Strategy instance can be thought of as objects wrapping a stack of DeFiActions connectors wired together to
/// (optimally) generate some yield on initial deposits. Strategies can be simple such as swapping into a yield-bearing
/// asset (such as stFLOW) or more complex DeFiActions stacks.
///
/// A StrategyComposer is tasked with the creation of a supported Strategy. It's within the stacking of DeFiActions
/// connectors that the true power of the components lies.
///
access(all) contract PMStrategiesV1 {

    access(all) let univ3FactoryEVMAddress: EVM.EVMAddress
    access(all) let univ3RouterEVMAddress: EVM.EVMAddress
    access(all) let univ3QuoterEVMAddress: EVM.EVMAddress

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// Contract-level config for extensibility (not yet used)
    access(self) let config: {String: {String: AnyStruct}}

    /// This strategy uses syWFLOWv vaults
    access(all) resource syWFLOWvStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// User-facing deposit connector
        access(self) var sink: {DeFiActions.Sink}
        /// User-facing withdrawal connector
        access(self) var source: {DeFiActions.Source}

        init(
            id: DeFiActions.UniqueIdentifier,
            sink: {DeFiActions.Sink},
            source: {DeFiActions.Source}
        ) {
            self.uniqueID = id
            self.sink = sink
            self.source = source
        }

        // Inherited from FlowYieldVaults.Strategy default implementation
        // access(all) view fun isSupportedCollateralType(_ type: Type): Bool

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return { self.sink.getSinkType(): true }
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
                return <- DeFiActionsUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
        }
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: [
                    self.sink.getComponentInfo(),
                    self.source.getComponentInfo()
                ]
            )
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// This strategy uses tauUSDF vaults (Tau Labs USDF Vault)
    access(all) resource tauUSDFvStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// User-facing deposit connector
        access(self) var sink: {DeFiActions.Sink}
        /// User-facing withdrawal connector
        access(self) var source: {DeFiActions.Source}

        init(
            id: DeFiActions.UniqueIdentifier,
            sink: {DeFiActions.Sink},
            source: {DeFiActions.Source}
        ) {
            self.uniqueID = id
            self.sink = sink
            self.source = source
        }

        // Inherited from FlowYieldVaults.Strategy default implementation
        // access(all) view fun isSupportedCollateralType(_ type: Type): Bool

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return { self.sink.getSinkType(): true }
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
                return <- DeFiActionsUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
        }
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: [
                    self.sink.getComponentInfo(),
                    self.source.getComponentInfo()
                ]
            )
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// StrategyComposer for ERC4626 vault strategies (e.g., syWFLOWvStrategy, tauUSDFvStrategy).
    access(all) resource ERC4626VaultStrategyComposer : FlowYieldVaults.StrategyComposer {
        /// { Strategy Type: { Collateral Type: { String: AnyStruct } } }
        access(self) let config: {Type: {Type: {String: AnyStruct}}}

        init(_ config: {Type: {Type: {String: AnyStruct}}}) {
            self.config = config
        }

        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            let composed: {Type: Bool} = {}
            for t in self.config.keys {
                composed[t] = true
            }
            return composed
        }

        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            let strategyConfig = self.config[forStrategy]
            if strategyConfig == nil {
                return {}
            }
            // Return all supported collateral types from config
            let supported: {Type: Bool} = {}
            for collateralType in strategyConfig!.keys {
                supported[collateralType] = true
            }
            return supported
        }

        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            let supportedInitVaults = self.getSupportedInitializationVaults(forStrategy: forStrategy)
            if supportedInitVaults[initializedWith] == true {
                return { initializedWith: true }
            }
            return {}
        }

        /// Composes a Strategy of the given type with the provided funds
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{FlowYieldVaults.Strategy} {
            let collateralType = withFunds.getType()
            let strategyConfig = self.config[type]
                ?? panic("Could not find a config for Strategy \(type.identifier)")
            let collateralConfig = strategyConfig[collateralType]
                ?? panic("Could not find config for collateral \(collateralType.identifier) when creating Strategy \(type.identifier)")

            // Get config values
            let yieldTokenEVMAddress = collateralConfig["yieldTokenEVMAddress"] as? EVM.EVMAddress 
                ?? panic("Could not find \"yieldTokenEVMAddress\" in config")
            let swapFeeTier = collateralConfig["swapFeeTier"] as? UInt32 
                ?? panic("Could not find \"swapFeeTier\" in config")

            // Get underlying asset EVM address from the deposited funds type
            let underlyingAssetEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: collateralType)
                ?? panic("Could not get EVM address for collateral type \(collateralType.identifier)")

            // assign yield token type from the tauUSDF ERC4626 vault address
            let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: yieldTokenEVMAddress)
                ?? panic("Could not retrieve the VM Bridge associated Type for the yield token address \(yieldTokenEVMAddress.toString())")

            // create the oracle for the assets to be held in the AutoBalancer retrieving the NAV of the 4626 vault
            let yieldTokenOracle = ERC4626PriceOracles.PriceOracle(
                    vault: yieldTokenEVMAddress,
                    asset: collateralType,
                    uniqueID: uniqueID
                )

            // Create recurring config for automatic rebalancing
            let recurringConfig = PMStrategiesV1._createRecurringConfig(withID: uniqueID)

            // configure and AutoBalancer for this stack with native recurring scheduling
            let autoBalancer = FlowYieldVaultsAutoBalancers._initNewAutoBalancer(
                    oracle: yieldTokenOracle,       // used to determine value of deposits & when to rebalance
                    vaultType: yieldTokenType,      // the type of Vault held by the AutoBalancer
                    lowerThreshold: 0.95,           // set AutoBalancer to pull from rebalanceSource when balance is 5% below value of deposits
                    upperThreshold: 1.05,           // set AutoBalancer to push to rebalanceSink when balance is 5% below value of deposits
                    rebalanceSink: nil,             // nil on init - will be set once a PositionSink is available
                    rebalanceSource: nil,           // nil on init - not set for Strategy
                    recurringConfig: recurringConfig, // enables native AutoBalancer self-scheduling
                    uniqueID: uniqueID              // identifies AutoBalancer as part of this Strategy
                )
            // enables deposits of YieldToken to the AutoBalancer
            let abaSink = autoBalancer.createBalancerSink() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")
            // enables withdrawals of YieldToken from the AutoBalancer
            let abaSource = autoBalancer.createBalancerSource() ?? panic("Could not retrieve Source from AutoBalancer with id \(uniqueID.id)")

            // create Collateral <-> YieldToken swappers
            //
            // Collateral -> YieldToken - can swap via two primary routes:
            // - via AMM swap pairing Collateral <-> YieldToken
            // - via ERC4626 vault deposit
            // Collateral -> YieldToken high-level Swapper contains:
            //     - MultiSwapper aggregates across two sub-swappers
            //         - Collateral -> YieldToken (UniV3 Swapper)
            //         - Collateral -> YieldToken (ERC4626 Swapper)
            let collateralToYieldAMMSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: PMStrategiesV1.univ3FactoryEVMAddress,
                    routerAddress: PMStrategiesV1.univ3RouterEVMAddress,
                    quoterAddress: PMStrategiesV1.univ3QuoterEVMAddress,
                    tokenPath: [underlyingAssetEVMAddress, yieldTokenEVMAddress],
                    feePath: [swapFeeTier],
                    inVault: collateralType,
                    outVault: yieldTokenType,
                    coaCapability: PMStrategiesV1._getCOACapability(),
                    uniqueID: uniqueID
                )
            // Swap Collateral -> YieldToken via ERC4626 Vault
            let collateralTo4626Swapper = ERC4626SwapConnectors.Swapper(
                    asset: collateralType,
                    vault: yieldTokenEVMAddress,
                    coa: PMStrategiesV1._getCOACapability(),
                    feeSource: PMStrategiesV1._createFeeSource(withID: uniqueID),
                    uniqueID: uniqueID
                )
            // Finally, add the two Collateral -> YieldToken swappers into an aggregate MultiSwapper
            let collateralToYieldSwapper = SwapConnectors.MultiSwapper(
                    inVault: collateralType,
                    outVault: yieldTokenType,
                    swappers: [collateralToYieldAMMSwapper, collateralTo4626Swapper],
                    uniqueID: uniqueID
                )

            // YieldToken -> Collateral
            // - Targets the Collateral <-> YieldToken pool as the only route since withdraws from the ERC4626 Vault are async
            let yieldToCollateralSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: PMStrategiesV1.univ3FactoryEVMAddress,
                    routerAddress: PMStrategiesV1.univ3RouterEVMAddress,
                    quoterAddress: PMStrategiesV1.univ3QuoterEVMAddress,
                    tokenPath: [yieldTokenEVMAddress, underlyingAssetEVMAddress],
                    feePath: [swapFeeTier],
                    inVault: yieldTokenType,
                    outVault: collateralType,
                    coaCapability: PMStrategiesV1._getCOACapability(),
                    uniqueID: uniqueID
                )

            // init SwapSink directing swapped funds to AutoBalancer
            //
            // Swaps provided Collateral to YieldToken & deposits to the AutoBalancer
            let abaSwapSink = SwapConnectors.SwapSink(swapper: collateralToYieldSwapper, sink: abaSink, uniqueID: uniqueID)
            // Swaps YieldToken & provides swapped Collateral, sourcing YieldToken from the AutoBalancer
            let abaSwapSource = SwapConnectors.SwapSource(swapper: yieldToCollateralSwapper, source: abaSource, uniqueID: uniqueID)

            // set the AutoBalancer's rebalance Sink which it will use to deposit overflown value, recollateralizing
            // the position
            autoBalancer.setSink(abaSwapSink, updateSinkID: true)
            abaSwapSink.depositCapacity(from: &withFunds as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

            assert(withFunds.balance == 0.0, message: "Vault should be empty after depositing")
            destroy withFunds

            // Use the same uniqueID passed to createStrategy so Strategy.burnCallback
            // calls _cleanupAutoBalancer with the correct ID
            switch type {
            case Type<@syWFLOWvStrategy>():
                return <-create syWFLOWvStrategy(id: uniqueID, sink: abaSwapSink, source: abaSwapSource)
            case Type<@tauUSDFvStrategy>():
                return <-create tauUSDFvStrategy(id: uniqueID, sink: abaSwapSink, source: abaSwapSource)
            default:
                panic("Unsupported strategy type \(type.identifier)")
            }
        }
    }

    access(all) entitlement Configure

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since Strategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowYieldVaults.StrategyComposerIssuer {
        /// { StrategyComposer Type: { Strategy Type: { Collateral Type: { String: AnyStruct } } } }
        access(all) let configs: {Type: {Type: {Type: {String: AnyStruct}}}}

        init(configs: {Type: {Type: {Type: {String: AnyStruct}}}}) {
            self.configs = configs
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { 
                Type<@ERC4626VaultStrategyComposer>(): true
            }
        }
        access(all) fun issueComposer(_ type: Type): @{FlowYieldVaults.StrategyComposer} {
            pre {
                self.getSupportedComposers()[type] == true:
                "Unsupported StrategyComposer \(type.identifier) requested"
                (&self.configs[type] as &{Type: {Type: {String: AnyStruct}}}?) != nil:
                "Could not find config for StrategyComposer \(type.identifier)"
            }
            switch type {
            case Type<@ERC4626VaultStrategyComposer>():
                return <- create ERC4626VaultStrategyComposer(self.configs[type]!)
            default:
                panic("Unsupported StrategyComposer \(type.identifier) requested")
            }
        }
        access(Configure) fun upsertConfigFor(composer: Type, config: {Type: {Type: {String: AnyStruct}}}) {
            pre {
                self.getSupportedComposers()[composer] == true:
                "Unsupported StrategyComposer Type \(composer.identifier)"
            }
            // Validate keys
            for stratType in config.keys {
                assert(stratType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()),
                    message: "Invalid config key \(stratType.identifier) - not a FlowYieldVaults.Strategy Type")
                for collateralType in config[stratType]!.keys {
                    assert(collateralType.isSubtype(of: Type<@{FungibleToken.Vault}>()),
                        message: "Invalid config key at config[\(stratType.identifier)] - \(collateralType.identifier) is not a FungibleToken.Vault")
                }
            }
            // Merge instead of overwrite
            let existingComposerConfig = self.configs[composer] ?? {}
            var mergedComposerConfig: {Type: {Type: {String: AnyStruct}}} = existingComposerConfig

            for stratType in config.keys {
                let newPerCollateral = config[stratType]!
                let existingPerCollateral = mergedComposerConfig[stratType] ?? {}
                var mergedPerCollateral: {Type: {String: AnyStruct}} = existingPerCollateral

                for collateralType in newPerCollateral.keys {
                    mergedPerCollateral[collateralType] = newPerCollateral[collateralType]!
                }
                mergedComposerConfig[stratType] = mergedPerCollateral
            }

            self.configs[composer] = mergedComposerConfig
        }
    }

    /// Returns the COA capability for this account
    /// TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
    access(self)
    fun _getCOACapability(): Capability<auth(EVM.Call, EVM.Bridge, EVM.Owner) &EVM.CadenceOwnedAccount> {
        let coaCap = self.account.capabilities.storage.issue<auth(EVM.Call, EVM.Bridge, EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)
        assert(coaCap.check(), message: "Could not issue COA capability")
        return coaCap
    }

    /// Returns a FungibleTokenConnectors.VaultSinkAndSource used to subsidize cross VM token movement in contract-
    /// defined strategies.
    access(self)
    fun _createFeeSource(withID: DeFiActions.UniqueIdentifier?): {DeFiActions.Sink, DeFiActions.Source} {
        let capPath = /storage/strategiesFeeSource
        if self.account.storage.type(at: capPath) == nil {
            let cap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
            self.account.storage.save(cap, to: capPath)
        }
        let vaultCap = self.account.storage.copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: capPath)
            ?? panic("Could not find fee source Capability at \(capPath)")
        return FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: vaultCap,
            uniqueID: withID
        )
    }

    /// Creates an AutoBalancerRecurringConfig for scheduled rebalancing.
    /// The txnFunder uses the contract's FlowToken vault to pay for scheduling fees.
    access(self)
    fun _createRecurringConfig(withID: DeFiActions.UniqueIdentifier?): DeFiActions.AutoBalancerRecurringConfig {
        // Create txnFunder that can provide/accept FLOW for scheduling fees
        let txnFunder = self._createTxnFunder(withID: withID)
        
        return DeFiActions.AutoBalancerRecurringConfig(
            interval: 60,  // Rebalance every 60 seconds
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 800,
            forceRebalance: false,
            txnFunder: txnFunder
        )
    }

    /// Creates a Sink+Source for the AutoBalancer to use for scheduling fees
    access(self)
    fun _createTxnFunder(withID: DeFiActions.UniqueIdentifier?): {DeFiActions.Sink, DeFiActions.Source} {
        let capPath = /storage/autoBalancerTxnFunder
        if self.account.storage.type(at: capPath) == nil {
            let cap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
            self.account.storage.save(cap, to: capPath)
        }
        let vaultCap = self.account.storage.copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: capPath)
            ?? panic("Could not find txnFunder Capability at \(capPath)")
        return FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: vaultCap,
            uniqueID: withID
        )
    }

    init(
        univ3FactoryEVMAddress: String,
        univ3RouterEVMAddress: String,
        univ3QuoterEVMAddress: String
    ) {
        self.univ3FactoryEVMAddress = EVM.addressFromString(univ3FactoryEVMAddress)
        self.univ3RouterEVMAddress = EVM.addressFromString(univ3RouterEVMAddress)
        self.univ3QuoterEVMAddress = EVM.addressFromString(univ3QuoterEVMAddress)
        self.IssuerStoragePath = StoragePath(identifier: "PMStrategiesV1ComposerIssuer_\(self.account.address)")!
        self.config = {}

        // Start with empty configs - strategy configs are added via upsertConfigFor admin transactions
        let configs: {Type: {Type: {Type: {String: AnyStruct}}}} = {
                Type<@ERC4626VaultStrategyComposer>(): {}
            }
        self.account.storage.save(<-create StrategyComposerIssuer(configs: configs), to: self.IssuerStoragePath)

        // TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
        // create a COA in this account
        if self.account.storage.type(at: /storage/evm) == nil {
            self.account.storage.save(<-EVM.createCadenceOwnedAccount(), to: /storage/evm)
            let cap = self.account.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(/storage/evm)
            self.account.capabilities.publish(cap, at: /public/evm)
        }
    }
}
