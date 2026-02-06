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
import "ERC4626Utils"
// Lending protocol
import "FlowCreditMarket"
// FlowYieldVaults platform
import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancers"
// scheduler
import "FlowTransactionScheduler"
// tokens
import "MOET"
// vm bridge
import "FlowEVMBridgeConfig"
// live oracles
import "ERC4626PriceOracles"

/// FlowYieldVaultsStrategiesV1_1
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
access(all) contract FlowYieldVaultsStrategiesV1_1 {

    access(all) let univ3FactoryEVMAddress: EVM.EVMAddress
    access(all) let univ3RouterEVMAddress: EVM.EVMAddress
    access(all) let univ3QuoterEVMAddress: EVM.EVMAddress

    access(all) let config: {String: AnyStruct} 

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    access(all) struct CollateralConfig {
        access(all) let yieldTokenEVMAddress: EVM.EVMAddress
        access(all) let yieldToCollateralUniV3AddressPath: [EVM.EVMAddress]
        access(all) let yieldToCollateralUniV3FeePath: [UInt32]

        init(
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldToCollateralUniV3AddressPath: [EVM.EVMAddress],
            yieldToCollateralUniV3FeePath: [UInt32]
        ) {
            pre {
                yieldToCollateralUniV3AddressPath.length > 1:
                    "Invalid UniV3 path length"
                yieldToCollateralUniV3FeePath.length == yieldToCollateralUniV3AddressPath.length - 1:
                    "Invalid UniV3 fee path length"
                yieldToCollateralUniV3AddressPath[0].equals(yieldTokenEVMAddress):
                    "UniV3 path must start with yield token"
            }

            self.yieldTokenEVMAddress = yieldTokenEVMAddress
            self.yieldToCollateralUniV3AddressPath = yieldToCollateralUniV3AddressPath
            self.yieldToCollateralUniV3FeePath = yieldToCollateralUniV3FeePath
        }
    }

    /// This strategy uses mUSDF vaults
    access(all) resource mUSDFStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: FlowCreditMarket.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(id: DeFiActions.UniqueIdentifier, collateralType: Type, position: FlowCreditMarket.Position) {
            self.uniqueID = id
            self.position = position
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
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

    access(all) struct TokenBundle {
        access(all) let moetTokenType: Type
        access(all) let moetTokenEVMAddress: EVM.EVMAddress

        access(all) let yieldTokenType: Type
        access(all) let yieldTokenEVMAddress: EVM.EVMAddress

        access(all) let underlying4626AssetType: Type
        access(all) let underlying4626AssetEVMAddress: EVM.EVMAddress

        init(
            moetTokenType: Type,
            moetTokenEVMAddress: EVM.EVMAddress,
            yieldTokenType: Type,
            yieldTokenEVMAddress: EVM.EVMAddress,
            underlying4626AssetType: Type,
            underlying4626AssetEVMAddress: EVM.EVMAddress
        ) {
            self.moetTokenType = moetTokenType
            self.moetTokenEVMAddress = moetTokenEVMAddress
            self.yieldTokenType = yieldTokenType
            self.yieldTokenEVMAddress = yieldTokenEVMAddress
            self.underlying4626AssetType = underlying4626AssetType
            self.underlying4626AssetEVMAddress = underlying4626AssetEVMAddress
        }
    }

    /// Returned bundle for stored AutoBalancer interactions (reference + caps)
    access(all) struct AutoBalancerIO {
        access(all) let autoBalancer:
            auth(DeFiActions.Auto, DeFiActions.Set, DeFiActions.Get, DeFiActions.Schedule, FungibleToken.Withdraw)
            &DeFiActions.AutoBalancer

        access(all) let sink: {DeFiActions.Sink}
        access(all) let source: {DeFiActions.Source}

        init(
            autoBalancer: auth(DeFiActions.Auto, DeFiActions.Set, DeFiActions.Get, DeFiActions.Schedule, FungibleToken.Withdraw) &DeFiActions.AutoBalancer,
            sink: {DeFiActions.Sink},
            source: {DeFiActions.Source}
        ) {
            self.sink = sink
            self.source = source
            self.autoBalancer = autoBalancer
        }
    }

    /// This StrategyComposer builds a mUSDFStrategy
    access(all) resource mUSDFStrategyComposer : FlowYieldVaults.StrategyComposer {
        /// { Strategy Type: { Collateral Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig } }
        access(self) let config: {Type: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}}

        init(_ config: {Type: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}}) {
            self.config = config
        }

        /// Returns the Types of Strategies composed by this StrategyComposer
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            let composed: {Type: Bool} = {}
            for t in self.config.keys {
                composed[t] = true
            }
            return composed
        }

        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            let supported: {Type: Bool} = {}
            if let strategyConfig = &self.config[forStrategy] as &{Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}? {
                for collateralType in strategyConfig.keys {
                    supported[collateralType] = true
                }
            }
            return supported
        }

        access(self) view fun _supportsCollateral(forStrategy: Type, collateral: Type): Bool {
            if let strategyConfig = self.config[forStrategy] {
                return strategyConfig[collateral] != nil
            }
            return false
        }

        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return self._supportsCollateral(forStrategy: forStrategy, collateral: initializedWith)
                ? { initializedWith: true }
                : {}
        }

        /// Composes a Strategy of the given type with the provided funds
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{FlowYieldVaults.Strategy} {
            let collateralType = withFunds.getType()

            let collateralConfig = self._getCollateralConfig(
                strategyType: type,
                collateralType: collateralType
            )

            let tokens = self._resolveTokenBundle(collateralConfig: collateralConfig)

            // Oracle used by AutoBalancer (tracks NAV of ERC4626 vault)
            let yieldTokenOracle = self._createYieldTokenOracle(
                yieldTokenEVMAddress: tokens.yieldTokenEVMAddress,
                underlyingAssetType: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )

            // Create recurring config for automatic rebalancing
            let recurringConfig = FlowYieldVaultsStrategiesV1_1._createRecurringConfig(withID: uniqueID)

            // Create/store/publish/register AutoBalancer (returns authorized ref)
            let balancerIO = self._initAutoBalancerAndIO(
                oracle: yieldTokenOracle,
                yieldTokenType: tokens.yieldTokenType,
                recurringConfig: recurringConfig,
                uniqueID: uniqueID
            )

            // Swappers: MOET <-> YIELD (YIELD is ERC4626 vault token)
            let moetToYieldSwapper = self._createMoetToYieldSwapper(tokens: tokens, uniqueID: uniqueID)

            let yieldToMoetSwapper = self._createUniV3Swapper(
                tokenPath: [tokens.yieldTokenEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [100],
                inVault: tokens.yieldTokenType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )

            // AutoBalancer-directed swap IO
            let abaSwapSink = SwapConnectors.SwapSink(
                swapper: moetToYieldSwapper,
                sink: balancerIO.sink,
                uniqueID: uniqueID
            )
            let abaSwapSource = SwapConnectors.SwapSource(
                swapper: yieldToMoetSwapper,
                source: balancerIO.source,
                uniqueID: uniqueID
            )

            // Open FlowCreditMarket position
            let position = self._openCreditPosition(
                funds: <-withFunds,
                issuanceSink: abaSwapSink,
                repaymentSource: abaSwapSource
            )

            // Position Sink/Source (only Sink needed here, Source stays inside Strategy impl)
            let positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)

            // Yield -> Collateral swapper for recollateralization
            let yieldToCollateralSwapper = self._createYieldToCollateralSwapper(
                collateralConfig: collateralConfig,
                yieldTokenEVMAddress: tokens.yieldTokenEVMAddress,
                yieldTokenType: tokens.yieldTokenType,
                collateralType: collateralType,
                uniqueID: uniqueID
            )

            let positionSwapSink = SwapConnectors.SwapSink(
                swapper: yieldToCollateralSwapper,
                sink: positionSink,
                uniqueID: uniqueID
            )

            // Set AutoBalancer sink for overflow -> recollateralize
            balancerIO.autoBalancer.setSink(positionSwapSink, updateSinkID: true)

            return <-create FlowYieldVaultsStrategiesV1_1.mUSDFStrategy(
                id: uniqueID,
                collateralType: collateralType,
                position: position
            )
        }

        /* ===========================
           Helpers
           =========================== */

        access(self) fun _getCollateralConfig(
            strategyType: Type,
            collateralType: Type
        ): FlowYieldVaultsStrategiesV1_1.CollateralConfig {
            let strategyConfig = self.config[strategyType]
                ?? panic(
                    "Could not find a config for Strategy \(strategyType.identifier) initialized with \(collateralType.identifier)"
                )

            return strategyConfig[collateralType]
                ?? panic(
                    "Could not find config for collateral \(collateralType.identifier) when creating Strategy \(strategyType.identifier)"
                )
        }

        access(self) fun _resolveTokenBundle(
            collateralConfig: FlowYieldVaultsStrategiesV1_1.CollateralConfig
        ): FlowYieldVaultsStrategiesV1_1.TokenBundle {
            // MOET
            let moetTokenType = Type<@MOET.Vault>()
            let moetTokenEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetTokenType)
                ?? panic("Token Vault type \(moetTokenType.identifier) has not yet been registered with the VMbridge")

            // YIELD (ERC4626 vault token)
            let yieldTokenEVMAddress = collateralConfig.yieldTokenEVMAddress
            let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: yieldTokenEVMAddress)
                ?? panic(
                    "Could not retrieve the VM Bridge associated Type for the yield token address \(yieldTokenEVMAddress.toString())"
                )

            // UNDERLYING asset of the ERC4626 vault
            let underlying4626AssetEVMAddress = ERC4626Utils.underlyingAssetEVMAddress(vault: yieldTokenEVMAddress)
                ?? panic(
                    "Could not get the underlying asset's EVM address for ERC4626Vault \(yieldTokenEVMAddress.toString())"
                )
            let underlying4626AssetType = FlowEVMBridgeConfig.getTypeAssociated(with: underlying4626AssetEVMAddress)
                ?? panic(
                    "Could not retrieve the VM Bridge associated Type for the ERC4626 underlying asset \(underlying4626AssetEVMAddress.toString())"
                )

            return FlowYieldVaultsStrategiesV1_1.TokenBundle(
                moetTokenType: moetTokenType,
                moetTokenEVMAddress: moetTokenEVMAddress,
                yieldTokenType: yieldTokenType,
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                underlying4626AssetType: underlying4626AssetType,
                underlying4626AssetEVMAddress: underlying4626AssetEVMAddress
            )
        }

        access(self) fun _createYieldTokenOracle(
            yieldTokenEVMAddress: EVM.EVMAddress,
            underlyingAssetType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): ERC4626PriceOracles.PriceOracle {
            return ERC4626PriceOracles.PriceOracle(
                vault: yieldTokenEVMAddress,
                asset: underlyingAssetType,
                uniqueID: uniqueID
            )
        }

        access(self) fun _createUniV3Swapper(
            tokenPath: [EVM.EVMAddress],
            feePath: [UInt32],
            inVault: Type,
            outVault: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            return UniswapV3SwapConnectors.Swapper(
                factoryAddress: FlowYieldVaultsStrategiesV1_1.univ3FactoryEVMAddress,
                routerAddress: FlowYieldVaultsStrategiesV1_1.univ3RouterEVMAddress,
                quoterAddress: FlowYieldVaultsStrategiesV1_1.univ3QuoterEVMAddress,
                tokenPath: tokenPath,
                feePath: feePath,
                inVault: inVault,
                outVault: outVault,
                coaCapability: FlowYieldVaultsStrategiesV1_1._getCOACapability(),
                uniqueID: uniqueID
            )
        }

        access(self) fun _createMoetToYieldSwapper(
            tokens: FlowYieldVaultsStrategiesV1_1.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            // Direct MOET -> YIELD via AMM
            let moetToYieldAMM = self._createUniV3Swapper(
                tokenPath: [tokens.moetTokenEVMAddress, tokens.yieldTokenEVMAddress],
                feePath: [100],
                inVault: tokens.moetTokenType,
                outVault: tokens.yieldTokenType,
                uniqueID: uniqueID
            )

            // MOET -> UNDERLYING via AMM
            let moetToUnderlying = self._createUniV3Swapper(
                tokenPath: [tokens.moetTokenEVMAddress, tokens.underlying4626AssetEVMAddress],
                feePath: [100],
                inVault: tokens.moetTokenType,
                outVault: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )

            // UNDERLYING -> YIELD via ERC4626 vault
            let underlyingTo4626 = ERC4626SwapConnectors.Swapper(
                asset: tokens.underlying4626AssetType,
                vault: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV1_1._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV1_1._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID
            )

            let seq = SwapConnectors.SequentialSwapper(
                swappers: [moetToUnderlying, underlyingTo4626],
                uniqueID: uniqueID
            )

            return SwapConnectors.MultiSwapper(
                inVault: tokens.moetTokenType,
                outVault: tokens.yieldTokenType,
                swappers: [moetToYieldAMM, seq],
                uniqueID: uniqueID
            )
        }

        access(self) fun _initAutoBalancerAndIO(
            oracle: {DeFiActions.PriceOracle},
            yieldTokenType: Type,
            recurringConfig: DeFiActions.AutoBalancerRecurringConfig?,
            uniqueID: DeFiActions.UniqueIdentifier
        ): FlowYieldVaultsStrategiesV1_1.AutoBalancerIO {
            // NOTE: This stores the AutoBalancer in FlowYieldVaultsAutoBalancers storage and returns an authorized ref.
            let autoBalancerRef =
                FlowYieldVaultsAutoBalancers._initNewAutoBalancer(
                    oracle: oracle,
                    vaultType: yieldTokenType,
                    lowerThreshold: 0.95,
                    upperThreshold: 1.05,
                    rebalanceSink: nil,
                    rebalanceSource: nil,
                    recurringConfig: recurringConfig,
                    uniqueID: uniqueID
                )

            let sink = autoBalancerRef.createBalancerSink()
                ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")
            let source = autoBalancerRef.createBalancerSource()
                ?? panic("Could not retrieve Source from AutoBalancer with id \(uniqueID.id)")

            return FlowYieldVaultsStrategiesV1_1.AutoBalancerIO(
                autoBalancer: autoBalancerRef,
                sink: sink,
                source: source
            )
        }

        access(self) fun _openCreditPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DeFiActions.Sink},
            repaymentSource: {DeFiActions.Source}
        ): FlowCreditMarket.Position {
            let poolCap = FlowYieldVaultsStrategiesV1_1.account.storage.copy<
                Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>
            >(from: FlowCreditMarket.PoolCapStoragePath)
                ?? panic("Missing or invalid pool capability")

            let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

            let pid = poolRef.createPosition(
                funds: <-funds,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: true
            )

            return FlowCreditMarket.Position(id: pid, pool: poolCap)
        }

        access(self) fun _createYieldToCollateralSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV1_1.CollateralConfig,
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldTokenType: Type,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            // CollateralConfig.init already validates:
            // - path length > 1
            // - fee length == path length - 1
            // - path[0] == yield token
            //
            // Keep a defensive check in case configs were migrated / constructed elsewhere.
            let tokenPath = collateralConfig.yieldToCollateralUniV3AddressPath
            assert(
                tokenPath[0].equals(yieldTokenEVMAddress),
                message:
                    "Config mismatch: expected yield token \(yieldTokenEVMAddress.toString()) but got \(tokenPath[0].toString())"
            )

            return self._createUniV3Swapper(
                tokenPath: tokenPath,
                feePath: collateralConfig.yieldToCollateralUniV3FeePath,
                inVault: yieldTokenType,
                outVault: collateralType,
                uniqueID: uniqueID
            )
        }
    }

    access(all) entitlement Configure

    access(self)
    fun makeCollateralConfig(
        yieldTokenEVMAddress: EVM.EVMAddress,
        yieldToCollateralAddressPath: [EVM.EVMAddress],
        yieldToCollateralFeePath: [UInt32]
    ): CollateralConfig {
        pre {
            yieldToCollateralAddressPath.length > 1:
                "Invalid Uniswap V3 swap path length"
            yieldToCollateralFeePath.length == yieldToCollateralAddressPath.length - 1:
                "Uniswap V3 fee path length must be path length - 1"
            yieldToCollateralAddressPath[0].equals(yieldTokenEVMAddress):
                "UniswapV3 swap path must start with yield token"
        }

        return CollateralConfig(
            yieldTokenEVMAddress:  yieldTokenEVMAddress,
            yieldToCollateralUniV3AddressPath: yieldToCollateralAddressPath,
            yieldToCollateralUniV3FeePath: yieldToCollateralFeePath
        )
    }
    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since Strategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowYieldVaults.StrategyComposerIssuer {
        /// { StrategyComposer Type: { Strategy Type: { Collateral Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig } } }
        access(all) var configs: {Type: {Type: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}}}

        init(configs: {Type: {Type: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}}}) {
            self.configs = configs
        }

        access(all) view fun hasConfig(
            composer: Type,
            strategy: Type,
            collateral: Type
        ): Bool {
            if let composerConfig = self.configs[composer] {
                if let strategyConfig = composerConfig[strategy] {
                    return strategyConfig[collateral] != nil
                }
            }
            return false
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { 
                Type<@mUSDFStrategyComposer>(): true
            }
        }

        access(self) view fun isSupportedComposer(_ type: Type): Bool {
            return type == Type<@mUSDFStrategyComposer>()
        }
        access(all) fun issueComposer(_ type: Type): @{FlowYieldVaults.StrategyComposer} {
            pre {
                self.isSupportedComposer(type) == true:
                "Unsupported StrategyComposer \(type.identifier) requested"
                self.configs[type] != nil:
                "Could not find config for StrategyComposer \(type.identifier)"
            }
            switch type {
            case Type<@mUSDFStrategyComposer>():
                return <- create mUSDFStrategyComposer(self.configs[type]!)
            default:
                panic("Unsupported StrategyComposer \(type.identifier) requested")
            }
        }

        access(Configure)
        fun upsertConfigFor(
            composer: Type,
            config: {Type: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}}
        ) {
            pre {
                self.isSupportedComposer(composer) == true:
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
            var mergedComposerConfig = existingComposerConfig

            for stratType in config.keys {
                let newPerCollateral = config[stratType]!
                let existingPerCollateral = mergedComposerConfig[stratType] ?? {}
                var mergedPerCollateral: {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig} = existingPerCollateral

                for collateralType in newPerCollateral.keys {
                    mergedPerCollateral[collateralType] = newPerCollateral[collateralType]!
                }
                mergedComposerConfig[stratType] = mergedPerCollateral
            }

            self.configs[composer] = mergedComposerConfig
        }

        access(Configure) fun addOrUpdateCollateralConfig(
            composer: Type,
            strategyType: Type,
            collateralVaultType: Type,
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldToCollateralAddressPath: [EVM.EVMAddress],
            yieldToCollateralFeePath: [UInt32]
        ) {
            pre {
                self.isSupportedComposer(composer) == true:
                    "Unsupported StrategyComposer Type \(composer.identifier)"
                strategyType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()):
                    "Strategy type \(strategyType.identifier) is not a FlowYieldVaults.Strategy"
                collateralVaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                    "Collateral type \(collateralVaultType.identifier) is not a FungibleToken.Vault"
            }

            // Base struct with shared addresses
            var base = FlowYieldVaultsStrategiesV1_1.makeCollateralConfig(
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                yieldToCollateralAddressPath: yieldToCollateralAddressPath,
                yieldToCollateralFeePath: yieldToCollateralFeePath
            )

            // Wrap into the nested config expected by upsertConfigFor
            let singleCollateralConfig = {
                strategyType: {
                    collateralVaultType: base
                }
            }

            self.upsertConfigFor(composer: composer, config: singleCollateralConfig)
        }
        access(Configure) fun purgeConfig() {
            self.configs = {
                Type<@mUSDFStrategyComposer>(): {
                    Type<@mUSDFStrategy>(): {} as {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig}
                }
            }
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
            interval: 60 * 10,  // Rebalance every 10 minutes
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
        univ3QuoterEVMAddress: String,
    ) {
        self.univ3FactoryEVMAddress = EVM.addressFromString(univ3FactoryEVMAddress)
        self.univ3RouterEVMAddress = EVM.addressFromString(univ3RouterEVMAddress)
        self.univ3QuoterEVMAddress = EVM.addressFromString(univ3QuoterEVMAddress)
        self.IssuerStoragePath = StoragePath(identifier: "FlowYieldVaultsStrategyV1_1ComposerIssuer_\(self.account.address)")!
        self.config = {}

        let moetType = Type<@MOET.Vault>()
        if FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>()) == nil {
            panic("Could not find EVM address for \(moetType.identifier) - ensure the asset is onboarded to the VM Bridge")
        }

        let configs = {
                Type<@mUSDFStrategyComposer>(): {
                    Type<@mUSDFStrategy>(): ({} as {Type: FlowYieldVaultsStrategiesV1_1.CollateralConfig})
                }
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
