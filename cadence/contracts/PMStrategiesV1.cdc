// standards
import "FungibleToken"
import "EVM"
// DeFiActions
import "DeFiActionsUtils"
import "DeFiActions"
import "SwapConnectors"
import "FungibleTokenConnectors"
// amm integration
import "UniswapV3SwapConnectors"
import "ERC4626SwapConnectors"
import "MorphoERC4626SwapConnectors"
import "ERC4626Utils"
// FlowYieldVaults platform
import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancers"
// vm bridge
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "EVMAmountUtils"
// live oracles
import "ERC4626PriceOracles"
// deferred redemption
import "FlowTransactionScheduler"
import "FlowEVMBridge"
import "FlowToken"
import "ScopedFTProviders"
import "FungibleTokenMetadataViews"

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

    access(all) event RedeemRequested(
        yieldVaultID: UInt64,
        userAddress: Address,
        shares: UFix64,
        vaultEVMAddressHex: String
    )
    access(all) event RedeemClaimed(
        yieldVaultID: UInt64,
        userAddress: Address,
        assetsReceivedEVM: UInt256,
        vaultEVMAddressHex: String
    )
    access(all) event RedeemCancelled(
        yieldVaultID: UInt64,
        userAddress: Address,
        vaultEVMAddressHex: String
    )

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
        /// Returns the NAV-based balance by calling convertToAssets on the ERC-4626 vault
        access(all) fun navBalance(ofToken: Type): UFix64 {
            return PMStrategiesV1._navBalanceFor(
                strategyType: self.getType(),
                collateralType: self.sink.getSinkType(),
                ofToken: ofToken,
                id: self.id()!
            )
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
        /// Closes the position by withdrawing all available collateral.
        /// For simple strategies without FlowALP positions, this just withdraws all available balance.
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            let availableBalance = self.availableBalance(ofToken: collateralType)
            return <- self.withdraw(maxAmount: availableBalance, ofToken: collateralType)
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
        /// Returns the NAV-based balance by calling convertToAssets on the ERC-4626 vault
        access(all) fun navBalance(ofToken: Type): UFix64 {
            return PMStrategiesV1._navBalanceFor(
                strategyType: self.getType(),
                collateralType: self.sink.getSinkType(),
                ofToken: ofToken,
                id: self.id()!
            )
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
        /// Closes the position by withdrawing all available collateral.
        /// For simple strategies without FlowALP positions, this just withdraws all available balance.
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            let availableBalance = self.availableBalance(ofToken: collateralType)
            return <- self.withdraw(maxAmount: availableBalance, ofToken: collateralType)
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

    /// This strategy uses FUSDEV vaults (Flow USD Expeditionary Vault)
    access(all) resource FUSDEVStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
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
        /// Returns the NAV-based balance by calling convertToAssets on the ERC-4626 vault
        access(all) fun navBalance(ofToken: Type): UFix64 {
            return PMStrategiesV1._navBalanceFor(
                strategyType: self.getType(),
                collateralType: self.sink.getSinkType(),
                ofToken: ofToken,
                id: self.id()!
            )
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
        /// Closes the position by withdrawing all available collateral.
        /// For simple strategies without FlowALP positions, this just withdraws all available balance.
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            let availableBalance = self.availableBalance(ofToken: collateralType)
            return <- self.withdraw(maxAmount: availableBalance, ofToken: collateralType)
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

    /// StrategyComposer for ERC4626 vault strategies (e.g., syWFLOWvStrategy, tauUSDFvStrategy, FUSDEVStrategy).
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

            // configure and AutoBalancer for this stack
            let autoBalancer = FlowYieldVaultsAutoBalancers._initNewAutoBalancer(
                    oracle: yieldTokenOracle,       // used to determine value of deposits & when to rebalance
                    vaultType: yieldTokenType,      // the type of Vault held by the AutoBalancer
                    lowerThreshold: 0.95,           // set AutoBalancer to pull from rebalanceSource when balance is 5% below value of deposits
                    upperThreshold: 1.05,           // set AutoBalancer to push to rebalanceSink when balance is 5% below value of deposits
                    rebalanceSink: nil,             // nil on init - will be set once a PositionSink is available
                    rebalanceSource: nil,           // nil on init - not set for Strategy
                    recurringConfig: nil,           // disables native AutoBalancer self-scheduling, no rebalancing required after init
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
            // Morpho vaults use MorphoERC4626SwapConnectors; standard ERC4626 vaults use ERC4626SwapConnectors
            var collateralToYieldSwapper: SwapConnectors.MultiSwapper? = nil
            if type == Type<@FUSDEVStrategy>() {
                let collateralToYieldMorphoERC4626Swapper = MorphoERC4626SwapConnectors.Swapper(
                        vaultEVMAddress: yieldTokenEVMAddress,
                        coa: PMStrategiesV1._getCOACapability(),
                        feeSource: PMStrategiesV1._createFeeSource(withID: uniqueID),
                        uniqueID: uniqueID,
                        isReversed: false
                    )
                collateralToYieldSwapper = SwapConnectors.MultiSwapper(
                        inVault: collateralType,
                        outVault: yieldTokenType,
                        swappers: [collateralToYieldAMMSwapper, collateralToYieldMorphoERC4626Swapper],
                        uniqueID: uniqueID
                    )
            } else {
                let collateralToYieldERC4626Swapper = ERC4626SwapConnectors.Swapper(
                        asset: collateralType,
                        vault: yieldTokenEVMAddress,
                        coa: PMStrategiesV1._getCOACapability(),
                        feeSource: PMStrategiesV1._createFeeSource(withID: uniqueID),
                        uniqueID: uniqueID
                    )
                collateralToYieldSwapper = SwapConnectors.MultiSwapper(
                        inVault: collateralType,
                        outVault: yieldTokenType,
                        swappers: [collateralToYieldAMMSwapper, collateralToYieldERC4626Swapper],
                        uniqueID: uniqueID
                    )
            }

            // create YieldToken <-> Collateral swappers
            //
            // YieldToken -> Collateral - can swap via two primary routes:
            // - via AMM swap pairing YieldToken <-> Collateral
            // - via ERC4626 vault deposit
            // YieldToken -> Collateral high-level Swapper contains:
            //     - MultiSwapper aggregates across two sub-swappers
            //         - YieldToken -> Collateral (UniV3 Swapper)
            //         - YieldToken -> Collateral (ERC4626 Swapper)
            let yieldToCollateralAMMSwapper = UniswapV3SwapConnectors.Swapper(
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

            // Reverse path: YieldToken -> Collateral
            // Morpho vaults support direct redeem; standard ERC4626 vaults use AMM-only path
            var yieldToCollateralSwapper: SwapConnectors.MultiSwapper? = nil
            if type == Type<@FUSDEVStrategy>() {
                let yieldToCollateralMorphoERC4626Swapper = MorphoERC4626SwapConnectors.Swapper(
                        vaultEVMAddress: yieldTokenEVMAddress,
                        coa: PMStrategiesV1._getCOACapability(),
                        feeSource: PMStrategiesV1._createFeeSource(withID: uniqueID),
                        uniqueID: uniqueID,
                        isReversed: true
                    )
                yieldToCollateralSwapper = SwapConnectors.MultiSwapper(
                        inVault: yieldTokenType,
                        outVault: collateralType,
                        swappers: [yieldToCollateralAMMSwapper, yieldToCollateralMorphoERC4626Swapper],
                        uniqueID: uniqueID
                    )
            } else {
                // Standard ERC4626: AMM-only reverse (no synchronous redeem support)
                yieldToCollateralSwapper = SwapConnectors.MultiSwapper(
                        inVault: yieldTokenType,
                        outVault: collateralType,
                        swappers: [yieldToCollateralAMMSwapper],
                        uniqueID: uniqueID
                    )
            }

            // init SwapSink directing swapped funds to AutoBalancer
            //
            // Swaps provided Collateral to YieldToken & deposits to the AutoBalancer
            let abaSwapSink = SwapConnectors.SwapSink(swapper: collateralToYieldSwapper!, sink: abaSink, uniqueID: uniqueID)
            // Swaps YieldToken & provides swapped Collateral, sourcing YieldToken from the AutoBalancer
            let abaSwapSource = SwapConnectors.SwapSource(swapper: yieldToCollateralSwapper!, source: abaSource, uniqueID: uniqueID)

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
            case Type<@FUSDEVStrategy>():
                return <-create FUSDEVStrategy(id: uniqueID, sink: abaSwapSink, source: abaSwapSource)
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

    /// Looks up the EVM vault address for a given strategy + collateral pair from the on-chain StrategyComposerIssuer config
    access(contract) fun _getYieldTokenEVMAddress(forStrategy: Type, collateralType: Type): EVM.EVMAddress? {
        let issuer = self.account.storage.borrow<&StrategyComposerIssuer>(from: self.IssuerStoragePath)
        if issuer == nil { return nil }
        if let composerConfig = issuer!.configs[Type<@ERC4626VaultStrategyComposer>()] {
            if let strategyConfig = composerConfig[forStrategy] {
                if let collateralConfig = strategyConfig[collateralType] {
                    // Dictionary access through references yields &EVM.EVMAddress, not EVM.EVMAddress;
                    // cast to reference, then reconstruct via addressFromString
                    if let addrRef = collateralConfig["yieldTokenEVMAddress"] as? &EVM.EVMAddress {
                        return EVM.addressFromString("0x\(addrRef.toString())")
                    }
                }
            }
        }
        return nil
    }

    /// Shared NAV balance computation: reads Cadence-side share balance from AutoBalancer,
    /// converts to underlying asset value via ERC-4626 convertToAssets
    access(contract) fun _navBalanceFor(strategyType: Type, collateralType: Type, ofToken: Type, id: UInt64): UFix64 {
        if ofToken != collateralType { return 0.0 }

        var nav = 0.0

        if let ab = FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: id) {
            let sharesBalance = ab.vaultBalance()
            if sharesBalance > 0.0 {
                let vaultAddr = self._getYieldTokenEVMAddress(forStrategy: strategyType, collateralType: collateralType)
                    ?? panic("No EVM vault address configured for \(strategyType.identifier)")

                let sharesWei = FlowEVMBridgeUtils.ufix64ToUInt256(
                    value: sharesBalance,
                    decimals: FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: vaultAddr)
                )

                let navWei = ERC4626Utils.convertToAssets(vault: vaultAddr, shares: sharesWei)
                    ?? panic("convertToAssets failed for vault ".concat(vaultAddr.toString()))

                let assetAddr = ERC4626Utils.underlyingAssetEVMAddress(vault: vaultAddr)
                    ?? panic("No underlying asset EVM address found for vault \(vaultAddr.toString())")

                nav = EVMAmountUtils.toCadenceOutForToken(navWei, erc20Address: assetAddr)
            }
        }

        return nav + self.getPendingRedeemNAVBalance(yieldVaultID: id)
    }

    /// Returns the COA capability for this account, issuing once and storing for reuse.
    /// TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
    access(self)
    fun _getCOACapability(): Capability<auth(EVM.Call, EVM.Bridge, EVM.Owner) &EVM.CadenceOwnedAccount> {
        let capPath = /storage/strategiesCOACap
        if self.account.storage.type(at: capPath) == nil {
            let coaCap = self.account.capabilities.storage.issue<auth(EVM.Call, EVM.Bridge, EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)
            assert(coaCap.check(), message: "Could not issue COA capability")
            self.account.storage.save(coaCap, to: capPath)
        }
        return self.account.storage.copy<Capability<auth(EVM.Call, EVM.Bridge, EVM.Owner) &EVM.CadenceOwnedAccount>>(from: capPath)
            ?? panic("Could not load COA capability from storage")
    }

    /// Returns the FlowToken vault capability for fee payment, issuing once and storing for reuse.
    access(self)
    fun _getFeeSourceCap(): Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}> {
        let capPath = /storage/strategiesFeeSource
        if self.account.storage.type(at: capPath) == nil {
            let cap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
            self.account.storage.save(cap, to: capPath)
        }
        return self.account.storage.copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>>(from: capPath)
            ?? panic("Could not load fee source capability")
    }

    /// Returns a FungibleTokenConnectors.VaultSinkAndSource used to subsidize cross VM token movement in contract-
    /// defined strategies.
    access(self)
    fun _createFeeSource(withID: DeFiActions.UniqueIdentifier?): {DeFiActions.Sink, DeFiActions.Source} {
        return FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: self._getFeeSourceCap(),
            uniqueID: withID
        )
    }

    // ──────────────────────────────────────────────────────────────────────
    // EVM helpers (More Vaults Diamond VaultFacet)
    // ──────────────────────────────────────────────────────────────────────

    access(self) fun _evmRequestRedeem(coa: auth(EVM.Call) &EVM.CadenceOwnedAccount, vault: EVM.EVMAddress, shares: UInt256) {
        let res = coa.call(
            to: vault,
            data: EVM.encodeABIWithSignature("requestRedeem(uint256)", [shares]),
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "requestRedeem failed: status \(res.status.rawValue)")
    }

    access(self) fun _evmClearRequest(coa: auth(EVM.Call) &EVM.CadenceOwnedAccount, vault: EVM.EVMAddress) {
        let res = coa.call(
            to: vault,
            data: EVM.encodeABIWithSignature("clearRequest()", [] as [AnyStruct]),
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "clearRequest failed: status \(res.status.rawValue)")
    }

    access(self) fun _evmApprove(coa: auth(EVM.Call) &EVM.CadenceOwnedAccount, token: EVM.EVMAddress, spender: EVM.EVMAddress, amount: UInt256) {
        let res = coa.call(
            to: token,
            data: EVM.encodeABIWithSignature("approve(address,uint256)", [spender, amount]),
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "approve failed: status \(res.status.rawValue)")
    }

    access(self) fun _evmRedeem(
        coa: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        vault: EVM.EVMAddress,
        shares: UInt256,
        receiver: EVM.EVMAddress,
        owner: EVM.EVMAddress
    ): UInt256 {
        let res = coa.call(
            to: vault,
            data: EVM.encodeABIWithSignature("redeem(uint256,address,address)", [shares, receiver, owner]),
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(res.status == EVM.Status.successful, message: "redeem failed: status \(res.status.rawValue)")
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: res.data)
        return decoded[0] as! UInt256
    }

    access(self) fun _evmGetWithdrawalTimelock(vault: EVM.EVMAddress): UInt64? {
        let coa = self.account.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA at /storage/evm for view call")
        let res = coa.dryCall(
            to: vault,
            data: EVM.encodeABIWithSignature("getWithdrawalTimelock()", [] as [AnyStruct]),
            gasLimit: 5_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        if res.status != EVM.Status.successful || res.data.length == 0 {
            return nil
        }
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: res.data)
        return UInt64(decoded[0] as! UInt256)
    }

    // ──────────────────────────────────────────────────────────────────────
    // Deferred Redemption (More Vaults withdrawal queue)
    // ──────────────────────────────────────────────────────────────────────

    /// Tracks a pending standard withdrawal waiting for timelock expiry.
    access(all) struct PendingRedeemInfo {
        access(all) let sharesEVM: UInt256
        access(all) let userCOAEVMAddress: EVM.EVMAddress
        access(all) let userFlowAddress: Address
        access(all) let vaultEVMAddress: EVM.EVMAddress
        access(all) let metadata: {String: AnyStruct}

        init(
            sharesEVM: UInt256,
            userCOAEVMAddress: EVM.EVMAddress,
            userFlowAddress: Address,
            vaultEVMAddress: EVM.EVMAddress
        ) {
            self.sharesEVM = sharesEVM
            self.userCOAEVMAddress = userCOAEVMAddress
            self.userFlowAddress = userFlowAddress
            self.vaultEVMAddress = vaultEVMAddress
            self.metadata = {}
        }
    }

    /// Single handler resource stored in the contract account. Multiple scheduled claims
    /// share this handler via capability; each schedule's data payload identifies which vault to process.
    access(all) resource PendingRedeemHandler: FlowTransactionScheduler.TransactionHandler {
        /// Keyed by yieldVaultID. Each user's YieldVault has a globally unique ID.
        access(contract) let pendingRedeems: {UInt64: PendingRedeemInfo}
        /// Keyed by yieldVaultID. Holds scheduled claim resources for status queries and cancellation.
        access(contract) let scheduledTxns: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// Safety margin added after the EVM timelock to ensure the claim executes after expiry.
        access(all) var schedulerBufferSeconds: UFix64
        /// Extensibility.
        access(all) let metadata: {String: AnyStruct}

        init() {
            self.pendingRedeems = {}
            self.scheduledTxns <- {}
            self.schedulerBufferSeconds = 30.0
            self.metadata = {}
        }

        access(Configure) fun setSchedulerBufferSeconds(_ seconds: UFix64) {
            self.schedulerBufferSeconds = seconds
        }

        access(all) view fun getViews(): [Type] { return [] }
        access(all) fun resolveView(_ view: Type): AnyStruct? { return nil }

        /// Called by FlowTransactionScheduler when the timelock expires.
        /// No-ops gracefully if the pending redeem was already cleared.
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let dataDict = data as? {String: AnyStruct}
                ?? panic("PendingRedeemHandler: invalid data format")
            let yieldVaultID = dataDict["yieldVaultID"] as? UInt64
                ?? panic("PendingRedeemHandler: missing yieldVaultID in data")

            if self.pendingRedeems[yieldVaultID] == nil {
                return
            }
            PMStrategiesV1._claimRedeem(yieldVaultID: yieldVaultID)
        }

        access(contract) fun setPendingRedeem(id: UInt64, info: PendingRedeemInfo) {
            self.pendingRedeems[id] = info
        }

        access(contract) fun removePendingRedeem(id: UInt64) {
            self.pendingRedeems.remove(key: id)
        }

        access(contract) view fun getPendingRedeem(id: UInt64): PendingRedeemInfo? {
            return self.pendingRedeems[id]
        }

        access(contract) fun setScheduledTx(id: UInt64, tx: @FlowTransactionScheduler.ScheduledTransaction) {
            if let old <- self.scheduledTxns.remove(key: id) {
                destroy old
            }
            self.scheduledTxns[id] <-! tx
        }

        access(contract) fun removeScheduledTx(id: UInt64) {
            if let tx <- self.scheduledTxns.remove(key: id) {
                // Properly cancel with the scheduler if still scheduled; otherwise just destroy
                if tx.status() == FlowTransactionScheduler.Status.Scheduled {
                    destroy FlowTransactionScheduler.cancel(scheduledTx: <-tx)
                } else {
                    destroy tx
                }
            }
        }

        access(contract) view fun getScheduledClaim(id: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
            return &self.scheduledTxns[id]
        }

        access(contract) view fun getAllPendingRedeemIDs(): [UInt64] {
            return self.pendingRedeems.keys
        }
    }

    /// Computes the storage path for the PendingRedeemHandler.
    access(self) view fun _pendingRedeemHandlerPath(): StoragePath {
        return StoragePath(identifier: "PMStrategiesV1PendingRedeemHandler")!
    }

    access(self) view fun _handlerCapStoragePath(): StoragePath {
        return StoragePath(identifier: "PMStrategiesV1PendingRedeemHandlerCap")!
    }

    /// Borrows the PendingRedeemHandler from contract account storage, or nil if not yet initialized.
    access(self) view fun _borrowHandler(): &PendingRedeemHandler? {
        return self.account.storage.borrow<&PendingRedeemHandler>(from: self._pendingRedeemHandlerPath())
    }

    /// Returns the reusable handler capability for FlowTransactionScheduler, issuing once on first call.
    access(self) fun _getHandlerSchedulerCap(): Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}> {
        let capPath = self._handlerCapStoragePath()
        if self.account.storage.type(at: capPath) == nil {
            let cap = self.account.capabilities.storage.issue<
                auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}
            >(self._pendingRedeemHandlerPath())
            self.account.storage.save(cap, to: capPath)
        }
        return self.account.storage.copy<
            Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
        >(from: capPath)
            ?? panic("Could not load handler capability from storage")
    }

    /// Creates a ScopedFTProvider for bridge fee payment from the contract's FlowToken vault.
    access(self) fun _createBridgeFeeProvider(): @ScopedFTProviders.ScopedFTProvider {
        return <- ScopedFTProviders.createScopedFTProvider(
            provider: self._getFeeSourceCap(),
            filters: [ScopedFTProviders.AllowanceFilter(FlowEVMBridgeUtils.calculateBridgeFee(bytes: 400_000))],
            expiration: getCurrentBlock().timestamp + 1.0
        )
    }

    /// Initiates a deferred redemption: converts underlying amount to shares on-chain,
    /// withdraws yield tokens from AutoBalancer, bridges to user's COA, calls
    /// requestRedeem + approve on EVM, records pending state, and schedules automated claim.
    ///
    /// @param yieldVaultID The user's YieldVault ID (also the AutoBalancer ID)
    /// @param amount Underlying asset amount to redeem (e.g., FLOW). Nil = redeem all.
    /// @param userCOA User's CadenceOwnedAccount reference for EVM calls
    /// @param userFlowAddress User's Flow address for claim delivery
    /// @param fees FlowToken vault to pay FlowTransactionScheduler scheduling fees
    access(all) fun requestRedeem(
        yieldVaultID: UInt64,
        amount: UFix64?,
        userCOA: auth(EVM.Call) &EVM.CadenceOwnedAccount,
        userFlowAddress: Address,
        fees: @FlowToken.Vault
    ) {
        let handler = self._borrowHandler()
            ?? panic("PendingRedeemHandler not initialized")
        assert(handler.getPendingRedeem(id: yieldVaultID) == nil, message: "Pending redeem already exists for vault \(yieldVaultID)")

        // Validate vault ownership: the user at userFlowAddress must own this YieldVault
        let managerRef = getAccount(userFlowAddress).capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(
            FlowYieldVaults.YieldVaultManagerPublicPath
        ) ?? panic("User has no YieldVaultManager")
        let yieldVault = managerRef.borrowYieldVault(id: yieldVaultID)
            ?? panic("User does not own vault \(yieldVaultID)")

        // Derive the vault EVM address from on-chain strategy config
        let strategyType = CompositeType(yieldVault.getStrategyType())
            ?? panic("Invalid strategy type \(yieldVault.getStrategyType())")
        let collateralType = CompositeType(yieldVault.getVaultTypeIdentifier())
            ?? panic("Invalid collateral type \(yieldVault.getVaultTypeIdentifier())")
        let vaultEVMAddress = self._getYieldTokenEVMAddress(forStrategy: strategyType, collateralType: collateralType)
            ?? panic("No EVM vault address configured for \(strategyType.identifier)")

        // Validate COA ownership: the provided COA must belong to userFlowAddress
        let publicCOA = getAccount(userFlowAddress).capabilities
            .borrow<&EVM.CadenceOwnedAccount>(/public/evm)
            ?? panic("User has no public COA at /public/evm")
        assert(
            publicCOA.address().bytes == userCOA.address().bytes,
            message: "Provided COA does not belong to user at \(userFlowAddress)"
        )

        let source = FlowYieldVaultsAutoBalancers.createExternalSource(id: yieldVaultID)
            ?? panic("Could not create external source for vault \(yieldVaultID)")

        // Convert underlying amount to target shares, or withdraw all if nil
        var targetShares = source.minimumAvailable()
        if let underlyingAmount = amount {
            let underlyingAddress = ERC4626Utils.underlyingAssetEVMAddress(vault: vaultEVMAddress)
                ?? panic("Could not get underlying asset address")
            let assetsEVM = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(
                underlyingAmount, erc20Address: underlyingAddress
            )
            let targetSharesEVM = ERC4626Utils.convertToShares(vault: vaultEVMAddress, assets: assetsEVM)
                ?? panic("convertToShares failed")
            targetShares = FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(
                targetSharesEVM, erc20Address: vaultEVMAddress
            )
        }

        // 1. Withdraw yield tokens from AutoBalancer
        let yieldTokenVault <- source.withdrawAvailable(maxAmount: targetShares)
        let shares = yieldTokenVault.balance
        assert(shares > 0.0, message: "No shares available to redeem")
        assert(
            amount == nil || shares >= targetShares * 0.9999,
            message: "Insufficient shares for requested amount: got \(shares), need >= \(targetShares * 0.9999)"
        )

        // 2. Bridge yield tokens from Cadence to user's COA on EVM
        let scopedProvider <- self._createBridgeFeeProvider()
        FlowEVMBridge.bridgeTokensToEVM(
            vault: <-yieldTokenVault,
            to: userCOA.address(),
            feeProvider: &scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )
        destroy scopedProvider

        // 3. Convert actual withdrawn shares to EVM and call requestRedeem
        let sharesEVM = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(shares, erc20Address: vaultEVMAddress)
        self._evmRequestRedeem(coa: userCOA, vault: vaultEVMAddress, shares: sharesEVM)

        // 4. Approve service COA to redeem on user's behalf
        let serviceCOA = self._getCOACapability().borrow()
            ?? panic("Could not borrow service COA")
        self._evmApprove(coa: userCOA, token: vaultEVMAddress, spender: serviceCOA.address(), amount: sharesEVM)

        // 5. Record pending redeem
        handler.setPendingRedeem(id: yieldVaultID, info: PendingRedeemInfo(
            sharesEVM: sharesEVM,
            userCOAEVMAddress: userCOA.address(),
            userFlowAddress: userFlowAddress,
            vaultEVMAddress: vaultEVMAddress
        ))

        // 6. Schedule automated claim after timelock expires.
        // FlowTransactionScheduler.Scheduled event carries the exact execution timestamp for backend ingestion.
        let timelockSeconds = self._evmGetWithdrawalTimelock(vault: vaultEVMAddress)
            ?? panic("Could not query withdrawal timelock")

        let scheduledTx <- FlowTransactionScheduler.schedule(
            handlerCap: self._getHandlerSchedulerCap(),
            data: {"yieldVaultID": yieldVaultID},
            timestamp: getCurrentBlock().timestamp + UFix64(timelockSeconds) + handler.schedulerBufferSeconds,
            priority: FlowTransactionScheduler.Priority.Low,
            executionEffort: 2500,
            fees: <-fees
        )

        handler.setScheduledTx(id: yieldVaultID, tx: <-scheduledTx)

        emit RedeemRequested(
            yieldVaultID: yieldVaultID,
            userAddress: userFlowAddress,
            shares: shares,
            vaultEVMAddressHex: vaultEVMAddress.toString()
        )
    }

    /// Called by PendingRedeemHandler.executeTransaction when the timelock has expired.
    /// Redeems shares via service COA, converts underlying ERC-20 to Cadence, deposits to user's wallet.
    access(self) fun _claimRedeem(yieldVaultID: UInt64) {
        let handler = self._borrowHandler()
            ?? panic("PendingRedeemHandler not initialized")
        let info = handler.getPendingRedeem(id: yieldVaultID)
            ?? panic("No pending redeem for vault \(yieldVaultID)")

        let coa = self._getCOACapability().borrow()
            ?? panic("Could not borrow service COA")

        // 1. Redeem: service COA calls redeem(shares, receiver=serviceCOA, owner=userCOA)
        let assetsReceived = self._evmRedeem(
            coa: coa,
            vault: info.vaultEVMAddress,
            shares: info.sharesEVM,
            receiver: coa.address(),
            owner: info.userCOAEVMAddress
        )

        // 2. Convert underlying ERC-20 tokens from EVM to Cadence and deliver to user
        let underlyingAddress = ERC4626Utils.underlyingAssetEVMAddress(vault: info.vaultEVMAddress)
            ?? panic("Could not get underlying asset address")

        let wflowAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@FlowToken.Vault>())
        if wflowAddress != nil && underlyingAddress.bytes == wflowAddress!.bytes {
            let unwrapResult = coa.call(
                to: underlyingAddress,
                data: EVM.encodeABIWithSignature("withdraw(uint256)", [assetsReceived]),
                gasLimit: 15_000_000,
                value: EVM.Balance(attoflow: 0)
            )
            assert(unwrapResult.status == EVM.Status.successful, message: "WFLOW unwrap failed")
            let flowVault <- coa.withdraw(balance: EVM.Balance(attoflow: UInt(assetsReceived)))
            let receiver = getAccount(info.userFlowAddress).capabilities
                .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
                ?? panic("Could not borrow user's FlowToken Receiver at \(info.userFlowAddress)")
            receiver.deposit(from: <-flowVault)
        } else {
            let underlyingCadenceType = FlowEVMBridgeConfig.getTypeAssociated(with: underlyingAddress)
                ?? panic("No Cadence type for underlying EVM address \(underlyingAddress.toString())")
            let bridgeFeeProvider <- self._createBridgeFeeProvider()
            let tokenVault <- coa.withdrawTokens(
                type: underlyingCadenceType,
                amount: assetsReceived,
                feeProvider: &bridgeFeeProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
            )
            destroy bridgeFeeProvider

            let vaultType = tokenVault.getType()
            let tokenContract = getAccount(vaultType.address!)
                .contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
                ?? panic("Could not borrow FungibleToken contract for \(vaultType.identifier)")
            let vaultData = tokenContract.resolveContractView(
                    resourceType: vaultType,
                    viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
                ) as? FungibleTokenMetadataViews.FTVaultData
                ?? panic("Could not resolve FTVaultData for \(vaultType.identifier)")
            let receiver = getAccount(info.userFlowAddress).capabilities
                .borrow<&{FungibleToken.Receiver}>(vaultData.receiverPath)
                ?? panic("User has no receiver for \(vaultType.identifier) at \(info.userFlowAddress)")
            receiver.deposit(from: <-tokenVault)
        }

        // 3. Cleanup
        emit RedeemClaimed(
            yieldVaultID: yieldVaultID,
            userAddress: info.userFlowAddress,
            assetsReceivedEVM: assetsReceived,
            vaultEVMAddressHex: info.vaultEVMAddress.toString()
        )
        handler.removePendingRedeem(id: yieldVaultID)
        handler.removeScheduledTx(id: yieldVaultID)
    }

    /// Cancels a pending deferred redemption: clears the EVM request, transfers shares back
    /// from user's COA to service COA, bridges back to Cadence, deposits to AutoBalancer.
    ///
    /// @param yieldVaultID The user's YieldVault ID
    /// @param userCOA User's CadenceOwnedAccount reference for EVM calls
    access(all) fun clearRedeemRequest(
        yieldVaultID: UInt64,
        userCOA: auth(EVM.Call) &EVM.CadenceOwnedAccount
    ) {
        let handler = self._borrowHandler()
            ?? panic("PendingRedeemHandler not initialized")
        let info = handler.getPendingRedeem(id: yieldVaultID)
            ?? panic("No pending redeem for vault \(yieldVaultID)")

        assert(
            userCOA.address().bytes == info.userCOAEVMAddress.bytes,
            message: "COA address does not match pending redeem requester"
        )

        // Extra safety: verify the COA is published by the original requester's Flow account
        let publicCOA = getAccount(info.userFlowAddress).capabilities
            .borrow<&EVM.CadenceOwnedAccount>(/public/evm)
            ?? panic("Original requester has no public COA at /public/evm")
        assert(
            publicCOA.address().bytes == userCOA.address().bytes,
            message: "Provided COA does not belong to original requester at \(info.userFlowAddress)"
        )

        // 1. Clear request on EVM
        self._evmClearRequest(coa: userCOA, vault: info.vaultEVMAddress)

        // 2. Transfer shares from user's COA back to service COA via ERC-20 transfer
        let serviceCOA = self._getCOACapability().borrow()
            ?? panic("Could not borrow service COA")
        let transferResult = userCOA.call(
            to: info.vaultEVMAddress,
            data: EVM.encodeABIWithSignature(
                "transfer(address,uint256)",
                [serviceCOA.address(), info.sharesEVM]
            ),
            gasLimit: 15_000_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(transferResult.status == EVM.Status.successful, message: "Share transfer back to service COA failed")

        // 2b. Revoke lingering ERC-20 approval (transfer doesn't consume allowance)
        self._evmApprove(coa: userCOA, token: info.vaultEVMAddress, spender: serviceCOA.address(), amount: 0)

        // 3. Bridge shares from service COA back to Cadence
        let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: info.vaultEVMAddress)
            ?? panic("Could not resolve Cadence type for vault \(info.vaultEVMAddress.toString())")
        let scopedProvider <- self._createBridgeFeeProvider()
        let yieldTokenVault <- serviceCOA.withdrawTokens(
            type: yieldTokenType,
            amount: info.sharesEVM,
            feeProvider: &scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )
        destroy scopedProvider

        // 4. Deposit back to AutoBalancer
        let sink = FlowYieldVaultsAutoBalancers.createExternalSink(id: yieldVaultID)
            ?? panic("Could not create external sink for vault \(yieldVaultID)")
        sink.depositCapacity(from: &yieldTokenVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        assert(yieldTokenVault.balance == 0.0, message: "Yield tokens should be fully deposited back")
        destroy yieldTokenVault

        // 5. Cancel scheduled transaction and cleanup
        emit RedeemCancelled(
            yieldVaultID: yieldVaultID,
            userAddress: info.userFlowAddress,
            vaultEVMAddressHex: info.vaultEVMAddress.toString()
        )
        handler.removeScheduledTx(id: yieldVaultID)
        handler.removePendingRedeem(id: yieldVaultID)
    }

    /// Returns the NAV value of pending redeem shares for a yield vault, or 0 if none.
    /// Converts shares → underlying via ERC-4626 convertToAssets, matching the same
    /// conversion used by _navBalanceFor (which calls this function).
    access(all) fun getPendingRedeemNAVBalance(yieldVaultID: UInt64): UFix64 {
        if let handler = self._borrowHandler() {
            if let info = handler.getPendingRedeem(id: yieldVaultID) {
                let navWei = ERC4626Utils.convertToAssets(vault: info.vaultEVMAddress, shares: info.sharesEVM)
                    ?? panic("convertToAssets failed for pending redeem")
                let assetAddr = ERC4626Utils.underlyingAssetEVMAddress(vault: info.vaultEVMAddress)
                    ?? panic("No underlying asset address for vault")
                return EVMAmountUtils.toCadenceOutForToken(navWei, erc20Address: assetAddr)
            }
        }
        return 0.0
    }

    /// Returns the full PendingRedeemInfo for a given yield vault, or nil if none.
    access(all) view fun getPendingRedeemInfo(yieldVaultID: UInt64): PendingRedeemInfo? {
        if let handler = self._borrowHandler() {
            return handler.getPendingRedeem(id: yieldVaultID)
        }
        return nil
    }

    /// Returns all yield vault IDs with active pending redeems; intended for operational audit and debugging.
    access(all) view fun getAllPendingRedeemIDs(): [UInt64] {
        if let handler = self._borrowHandler() {
            return handler.getAllPendingRedeemIDs()
        }
        return []
    }

    /// Returns the scheduled claim transaction for a yield vault, or nil if none.
    /// Callers can read .id, .timestamp, and .status() on the returned reference.
    access(all) view fun getScheduledClaim(yieldVaultID: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
        if let handler = self._borrowHandler() {
            return handler.getScheduledClaim(id: yieldVaultID)
        }
        return nil
    }

    /// Returns the current scheduler buffer (seconds added after EVM timelock), or nil if handler not initialized.
    access(all) view fun getSchedulerBufferSeconds(): UFix64? {
        if let handler = self._borrowHandler() {
            return handler.schedulerBufferSeconds
        }
        return nil
    }

    /// Initializes the PendingRedeemHandler. Must be called once via admin transaction
    /// after contract update, before any deferred redemptions can be processed.
    /// access(all) is safe: idempotent no-op when handler exists, writes only to contract's own storage.
    access(all) fun initPendingRedeemHandler() {
        let path = self._pendingRedeemHandlerPath()
        if self.account.storage.type(at: path) != nil {
            return
        }
        self.account.storage.save(<-create PendingRedeemHandler(), to: path)
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
