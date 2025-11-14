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
// Lending protocol
import "FlowALP"
// FlowVaults platform
import "FlowVaultsClosedBeta"
import "FlowVaults"
import "FlowVaultsAutoBalancers"
// tokens
import "YieldToken"
import "MOET"
// vm bridge
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "FlowEVMBridge"
// live oracles
import "ERC4626PriceOracles"
// mocks
import "MockOracle"
import "MockSwapper"

/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// FlowVaultsStrategies
///
/// This contract defines Strategies used in the FlowVaults platform.
///
/// A Strategy instance can be thought of as objects wrapping a stack of DeFiActions connectors wired together to
/// (optimally) generate some yield on initial deposits. Strategies can be simple such as swapping into a yield-bearing
/// asset (such as stFLOW) or more complex DeFiActions stacks.
///
/// A StrategyComposer is tasked with the creation of a supported Strategy. It's within the stacking of DeFiActions
/// connectors that the true power of the components lies.
///
access(all) contract FlowVaultsStrategies {

    access(all) let univ3FactoryEVMAddress: EVM.EVMAddress
    access(all) let univ3RouterEVMAddress: EVM.EVMAddress
    access(all) let univ3QuoterEVMAddress: EVM.EVMAddress
    access(all) let yieldTokenEVMAddress: EVM.EVMAddress

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// This is the first Strategy implementation, wrapping a FlowALP Position along with its related Sink &
    /// Source. While this object is a simple wrapper for the top-level collateralized position, the true magic of the
    /// DeFiActions is in the stacking of the related connectors. This stacking logic can be found in the
    /// TracerStrategyComposer construct.
    access(all) resource TracerStrategy : FlowVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: FlowALP.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(id: DeFiActions.UniqueIdentifier, collateralType: Type, position: FlowALP.Position) {
            self.uniqueID = id
            self.position = position
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
        }

        // Inherited from FlowVaults.Strategy default implementation
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
            FlowVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
        }
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// This StrategyComposer builds a TracerStrategy
    access(all) resource TracerStrategyComposer : FlowVaults.StrategyComposer {
        /// Returns the Types of Strategies composed by this StrategyComposer
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            return { Type<@TracerStrategy>(): true }
        }

        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }

        /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
        /// provided Vault type
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }

        /// Composes a Strategy of the given type with the provided funds
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{FlowVaults.Strategy} {
            // this PriceOracle is mocked and will be shared by all components used in the TracerStrategy
            // TODO: add ERC4626 price oracle
            let oracle = MockOracle.PriceOracle()

            // assign token types

            let moetTokenType: Type = Type<@MOET.Vault>()
            let yieldTokenType = Type<@YieldToken.Vault>()
            // assign collateral & flow token types
            let collateralType = withFunds.getType()

            // configure and AutoBalancer for this stack
            let autoBalancer = FlowVaultsAutoBalancers._initNewAutoBalancer(
                oracle: oracle,             // used to determine value of deposits & when to rebalance
                vaultType: yieldTokenType,  // the type of Vault held by the AutoBalancer
                lowerThreshold: 0.95,       // set AutoBalancer to pull from rebalanceSource when balance is 5% below value of deposits
                upperThreshold: 1.05,       // set AutoBalancer to push to rebalanceSink when balance is 5% below value of deposits
                rebalanceSink: nil,         // nil on init - will be set once a PositionSink is available
                rebalanceSource: nil,       // nil on init - not set for TracerStrategy
                uniqueID: uniqueID          // identifies AutoBalancer as part of this Strategy
            )
            // enables deposits of YieldToken to the AutoBalancer
            let abaSink = autoBalancer.createBalancerSink() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")
            // enables withdrawals of YieldToken from the AutoBalancer
            let abaSource = autoBalancer.createBalancerSource() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")

            // init Stable <> YIELD swappers
            //
            // Stable -> YieldToken
            let stableToYieldSwapper = MockSwapper.Swapper(
                inVault: moetTokenType,
                outVault: yieldTokenType,
                uniqueID: uniqueID
            )
            // YieldToken -> Stable
            let yieldToStableSwapper = MockSwapper.Swapper(
                inVault: yieldTokenType,
                outVault: moetTokenType,
                uniqueID: uniqueID
            )

            // init SwapSink directing swapped funds to AutoBalancer
            //
            // Swaps provided Stable to YieldToken & deposits to the AutoBalancer
            let abaSwapSink = SwapConnectors.SwapSink(swapper: stableToYieldSwapper, sink: abaSink, uniqueID: uniqueID)
            // Swaps YieldToken & provides swapped Stable, sourcing YieldToken from the AutoBalancer
            let abaSwapSource = SwapConnectors.SwapSource(swapper: yieldToStableSwapper, source: abaSource, uniqueID: uniqueID)

            // open a FlowALP position
            let poolCap = FlowVaultsStrategies.account.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(
                from: FlowALP.PoolCapStoragePath
            ) ?? panic("Missing pool capability")

            let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

            let pid = poolRef.createPosition(
                funds: <-withFunds,
                issuanceSink: abaSwapSink,
                repaymentSource: abaSwapSource,
                pushToDrawDownSink: true
            )
            let position = FlowALP.Position(id: pid, pool: poolCap)
            FlowVaultsStrategies.account.storage.save(poolCap, to: FlowALP.PoolCapStoragePath)

            // get Sink & Source connectors relating to the new Position
            let positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)
            let positionSource = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true) // TODO: may need to be false

            // init YieldToken -> FLOW Swapper
            let yieldToFlowSwapper = MockSwapper.Swapper(
                inVault: yieldTokenType,
                outVault: collateralType, 
                uniqueID: uniqueID
            )
            // allows for YieldToken to be deposited to the Position
            let positionSwapSink = SwapConnectors.SwapSink(swapper: yieldToFlowSwapper, sink: positionSink, uniqueID: uniqueID)

            // set the AutoBalancer's rebalance Sink which it will use to deposit overflown value,
            // recollateralizing the position
            autoBalancer.setSink(positionSwapSink, updateSinkID: true)

            return <-create TracerStrategy(
                id: DeFiActions.createUniqueIdentifier(),
                collateralType: collateralType,
                position: position
            )
        }
    }

    /// This strategy uses mUSDC vaults
    access(all) resource mUSDCStrategy : FlowVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: FlowALP.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(id: DeFiActions.UniqueIdentifier, collateralType: Type, position: FlowALP.Position) {
            self.uniqueID = id
            self.position = position
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
        }

        // Inherited from FlowVaults.Strategy default implementation
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
            FlowVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
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

    /// This StrategyComposer builds a mUSDCStrategy
    access(all) resource mUSDCStrategyComposer : FlowVaults.StrategyComposer {
        /// { Strategy Type: { Collateral Type: { String: AnyStruct } } }
        access(self) let config: {Type: {Type: {String: AnyStruct}}}

        init(_ config: {Type: {Type: {String: AnyStruct}}}) {
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
            if let strategyConfig = &self.config[forStrategy] as &{Type: {String: AnyStruct}}? {
                for collateralType in strategyConfig.keys {
                    supported[collateralType] = true
                }
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
        ): @{FlowVaults.Strategy} {
            let collateralType = withFunds.getType()
            let strategyConfig = self.config[type]
                ?? panic("Could not find a config for Strategy \(type.identifier) initialized with \(collateralType.identifier)")
            let collateralConfig = strategyConfig[collateralType]
                ?? panic("Could not find config for collateral \(collateralType.identifier) when creating Strategy \(type.identifier)")

            // assign token types & associated EVM Addresses
            let moetTokenType: Type = Type<@MOET.Vault>()
            let moetTokenEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetTokenType)
                ?? panic("Token Vault type \(moetTokenType.identifier) has not yet been registered with the VMbridge")
            let yieldTokenEVMAddress = collateralConfig["yieldTokenEVMAddress"] as? EVM.EVMAddress ?? panic("Could not find \"yieldTokenEVMAddress\" in config")
            let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: yieldTokenEVMAddress)
                ?? panic("Could not retrieve the VM Bridge associated Type for the yield token address \(yieldTokenEVMAddress.toString())")

            // assign underlying asset EVM address & type - assumed to be stablecoin for the tracer strategy
            let underlying4626AssetEVMAddress = ERC4626Utils.underlyingAssetEVMAddress(
                    vault: yieldTokenEVMAddress
                ) ?? panic("Could not get the underlying asset's EVM address for ERC4626Vault \(yieldTokenEVMAddress.toString())")
            let underlying4626AssetType = FlowEVMBridgeConfig.getTypeAssociated(with: underlying4626AssetEVMAddress)
                ?? panic("Could not retrieve the VM Bridge associated Type for the ERC4626 underlying asset \(underlying4626AssetEVMAddress.toString())")

            // create the oracle for the assets to be held in the AutoBalancer retrieving the NAV of the 4626 vault
            let yieldTokenOracle = ERC4626PriceOracles.PriceOracle(
                    vault: yieldTokenEVMAddress,
                    asset: underlying4626AssetType,
                    // asset: moetTokenType, // TODO: make a composite oracle that returns the price denominated in MOET
                    uniqueID: uniqueID
                )

            // configure and AutoBalancer for this stack
            let autoBalancer = FlowVaultsAutoBalancers._initNewAutoBalancer(
                    oracle: yieldTokenOracle,   // used to determine value of deposits & when to rebalance
                    vaultType: yieldTokenType,  // the type of Vault held by the AutoBalancer
                    lowerThreshold: 0.95,       // set AutoBalancer to pull from rebalanceSource when balance is 5% below value of deposits
                    upperThreshold: 1.05,       // set AutoBalancer to push to rebalanceSink when balance is 5% below value of deposits
                    rebalanceSink: nil,         // nil on init - will be set once a PositionSink is available
                    rebalanceSource: nil,       // nil on init - not set for TracerStrategy
                    uniqueID: uniqueID          // identifies AutoBalancer as part of this Strategy
                )
            // enables deposits of YieldToken to the AutoBalancer
            let abaSink = autoBalancer.createBalancerSink() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")
            // enables withdrawals of YieldToken from the AutoBalancer
            let abaSource = autoBalancer.createBalancerSource() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")

            // create MOET <-> YIELD swappers
            //
            // get Uniswap V3 addresses from config
            let univ3FactoryEVMAddress = collateralConfig["univ3FactoryEVMAddress"] as? EVM.EVMAddress ?? panic("Could not find \"univ3FactoryEVMAddress\" in config")
            let univ3RouterEVMAddress = collateralConfig["univ3RouterEVMAddress"] as? EVM.EVMAddress ?? panic("Could not find \"univ3RouterEVMAddress\" in config")
            let univ3QuoterEVMAddress = collateralConfig["univ3QuoterEVMAddress"] as? EVM.EVMAddress ?? panic("Could not find \"univ3QuoterEVMAddress\" in config")
            // MOET -> YIELD - MOET can swap to YieldToken via two primary routes
            // - via AMM swap pairing MOET <-> YIELD
            // - via 4626 vault, swapping first to underlying asset then depositing to the 4626 vault
            // MOET -> YIELD high-level Swapper then contains
            //     - MultiSwapper aggregates across two sub-swappers
            //         - MOET -> YIELD (UniV3 Swapper)
            //         - SequentialSwapper
            //             - MOET -> UNDERLYING (UniV3 Swapper)
            //             - UNDERLYING -> YIELD (ERC4626Swapper)
            let moetToYieldAMMSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: univ3FactoryEVMAddress,
                    routerAddress: univ3RouterEVMAddress,
                    quoterAddress: univ3QuoterEVMAddress,
                    tokenPath: [moetTokenEVMAddress, yieldTokenEVMAddress],
                    feePath: [3000],
                    inVault: moetTokenType,
                    outVault: yieldTokenType,
                    coaCapability: FlowVaultsStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )
            // Swap MOET -> UNDERLYING via AMM
            let moetToUnderlyingAssetSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: univ3FactoryEVMAddress,
                    routerAddress: univ3RouterEVMAddress,
                    quoterAddress: univ3QuoterEVMAddress,
                    tokenPath: [moetTokenEVMAddress, underlying4626AssetEVMAddress],
                    feePath: [3000],
                    inVault: moetTokenType,
                    outVault: yieldTokenType,
                    coaCapability: FlowVaultsStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )
            // Swap UNDERLYING -> YIELD via ERC4626 Vault
            let underlyingTo4626Swapper = ERC4626SwapConnectors.Swapper(
                    asset: underlying4626AssetType,
                    vault: yieldTokenEVMAddress,
                    coa: FlowVaultsStrategies._getCOACapability(),
                    feeSource: FlowVaultsStrategies._createFeeSource(withID: uniqueID),
                    uniqueID: uniqueID
                )
            // Compose v3 swapper & 4626 swapper into sequential swapper for MOET -> UNDERLYING -> YIELD
            let moetToYieldSeqSwapper = SwapConnectors.SequentialSwapper(
                    swappers: [moetToUnderlyingAssetSwapper, underlyingTo4626Swapper],
                    uniqueID: uniqueID
                )
            // Finally, add the two MOET -> YIELD swappers into an aggregate MultiSwapper
            let moetToYieldSwapper = SwapConnectors.MultiSwapper(
                    inVault: moetTokenType,
                    outVault: yieldTokenType,
                    swappers: [moetToYieldAMMSwapper, moetToYieldSeqSwapper],
                    uniqueID: uniqueID
                )

            // YIELD -> MOET
            // - Targets the MOET <-> YIELD pool as the only route since withdraws from the ERC4626 Vault are async
            let yieldToMOETSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: univ3FactoryEVMAddress,
                    routerAddress: univ3RouterEVMAddress,
                    quoterAddress: univ3QuoterEVMAddress,
                    tokenPath: [yieldTokenEVMAddress, moetTokenEVMAddress],
                    feePath: [3000],
                    inVault: yieldTokenType,
                    outVault: moetTokenType,
                    coaCapability: FlowVaultsStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )

            // init SwapSink directing swapped funds to AutoBalancer
            //
            // Swaps provided MOET to YIELD & deposits to the AutoBalancer
            let abaSwapSink = SwapConnectors.SwapSink(swapper: moetToYieldSwapper, sink: abaSink, uniqueID: uniqueID)
            // Swaps YIELD & provides swapped MOET, sourcing YIELD from the AutoBalancer
            let abaSwapSource = SwapConnectors.SwapSource(swapper: yieldToMOETSwapper, source: abaSource, uniqueID: uniqueID)

            // open a FlowALP position
            let poolCap = FlowVaultsStrategies.account.storage.copy<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(
                    from: FlowALP.PoolCapStoragePath
                ) ?? panic("Missing or invalid pool capability")
            let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

            let pid = poolRef.createPosition(
                    funds: <-withFunds,
                    issuanceSink: abaSwapSink,
                    repaymentSource: abaSwapSource,
                    pushToDrawDownSink: true
                )
            let position = FlowALP.Position(id: pid, pool: poolCap)

            // get Sink & Source connectors relating to the new Position
            let positionSink = position.createSinkWithOptions(type: collateralType, pushToDrawDownSink: true)
            let positionSource = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)

            // init YieldToken -> FLOW Swapper
            //
            // get UniswapV3 path configs
            let collateralUniV3AddressPathConfig = collateralConfig["yieldToCollateralUniV3AddressPaths"] as? {Type: [EVM.EVMAddress]}
                ?? panic("Could not find UniswapV3 address paths config when creating Strategy \(type.identifier) with collateral \(collateralType.identifier)")
            let uniV3AddressPath = collateralUniV3AddressPathConfig[collateralType]
                ?? panic("Could not find UniswapV3 address path for collateral type \(collateralType.identifier)")
            assert(uniV3AddressPath.length > 1, message: "Invalid Uniswap V3 swap path length of \(uniV3AddressPath.length)")
            assert(uniV3AddressPath[0].equals(yieldTokenEVMAddress),
                message: "UniswapV3 swap path does not match - expected path[0] to be \(yieldTokenEVMAddress.toString()) but found \(uniV3AddressPath[0].toString())") 
            let collateralUniV3FeePathConfig = collateralConfig["yieldToCollateralUniV3FeePaths"] as? {Type: [UInt32]}
                ?? panic("Could not find UniswapV3 fee paths config when creating Strategy \(type.identifier) with collateral \(collateralType.identifier)")
            let uniV3FeePath = collateralUniV3FeePathConfig[collateralType]
                ?? panic("Could not find UniswapV3 fee path for collateral type \(collateralType.identifier)")
            assert(uniV3FeePath.length > 0, message: "Invalid Uniswap V3 fee path length of \(uniV3FeePath.length)")
            // initialize the swapper used for recollateralization of the lending position as YIELD increases in value
            let yieldToFlowSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: univ3FactoryEVMAddress,
                    routerAddress: univ3RouterEVMAddress,
                    quoterAddress: univ3QuoterEVMAddress,
                    tokenPath: uniV3AddressPath,
                    feePath: uniV3FeePath,
                    inVault: yieldTokenType,
                    outVault: collateralType,
                    coaCapability: FlowVaultsStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )
            // allows for YIELD to be deposited to the Position as the collateral basis
            let positionSwapSink = SwapConnectors.SwapSink(swapper: yieldToFlowSwapper, sink: positionSink, uniqueID: uniqueID)

            // set the AutoBalancer's rebalance Sink which it will use to deposit overflown value, recollateralizing
            // the position
            autoBalancer.setSink(positionSwapSink, updateSinkID: true)

            return <-create mUSDCStrategy(
                id: DeFiActions.createUniqueIdentifier(),
                collateralType: collateralType,
                position: position
            )
        }
    }

    access(all) entitlement Configure

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since TracerStrategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowVaults.StrategyComposerIssuer {
        /// { StrategyComposer Type: { Strategy Type: { Collateral Type: { String: AnyStruct } } } }
        access(all) let configs: {Type: {Type: {Type: {String: AnyStruct}}}}

        init(configs: {Type: {Type: {Type: {String: AnyStruct}}}}) {
            self.configs = configs
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { 
                Type<@mUSDCStrategyComposer>(): true,
                Type<@TracerStrategyComposer>(): true
            }
        }
        access(all) fun issueComposer(_ type: Type): @{FlowVaults.StrategyComposer} {
            pre {
                self.getSupportedComposers()[type] == true:
                "Unsupported StrategyComposer \(type.identifier) requested"
                (&self.configs[type] as &{Type: {Type: {String: AnyStruct}}}?) != nil:
                "Could not find config for StrategyComposer \(type.identifier)"
            }
            switch type {
            case Type<@mUSDCStrategyComposer>():
                return <- create mUSDCStrategyComposer(self.configs[type]!)
            case Type<@TracerStrategyComposer>():
                return <- create TracerStrategyComposer()
            default:
                panic("Unsupported StrategyComposer \(type.identifier) requested")
            }
        }
        access(Configure) fun upsertConfigFor(composer: Type, config: {Type: {Type: {String: AnyStruct}}}) {
            pre {
                self.getSupportedComposers()[composer] == true:
                "Unsupported StrategyComposer Type \(composer.identifier)"
            }
            for stratType in config.keys {
                assert(stratType.isSubtype(of: Type<@{FlowVaults.Strategy}>()),
                    message: "Invalid config key \(stratType.identifier) - not a FlowVaults.Strategy Type")
                for collateralType in config[stratType]!.keys {
                    assert(collateralType.isSubtype(of: Type<@{FungibleToken.Vault}>()),
                        message: "Invalid config key at config[\(stratType.identifier)] - \(collateralType.identifier) is not a FungibleToken.Vault")
                }
            }
            self.configs[composer] = config
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

    init(
        univ3FactoryEVMAddress: String,
        univ3RouterEVMAddress: String,
        univ3QuoterEVMAddress: String,
        yieldTokenEVMAddress: String,
        recollateralizationUniV3AddressPath: [String],
        recollateralizationUniV3FeePath: [UInt32],
    ) {
        self.univ3FactoryEVMAddress = EVM.addressFromString(univ3FactoryEVMAddress)
        self.univ3RouterEVMAddress = EVM.addressFromString(univ3RouterEVMAddress)
        self.univ3QuoterEVMAddress = EVM.addressFromString(univ3QuoterEVMAddress)
        self.yieldTokenEVMAddress = EVM.addressFromString(yieldTokenEVMAddress)
        self.IssuerStoragePath = StoragePath(identifier: "FlowVaultsStrategyComposerIssuer_\(self.account.address)")!

        let initialCollateralType = Type<@FlowToken.Vault>()
        let moetType = Type<@MOET.Vault>()
        let moetEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>())
            ?? panic("Could not find EVM address for \(moetType.identifier) - ensure the asset is onboarded to the VM Bridge")
        let yieldTokenEVMAddress = EVM.addressFromString(yieldTokenEVMAddress)

        let swapAddressPath: [EVM.EVMAddress] = []
        for hex in recollateralizationUniV3AddressPath {
            swapAddressPath.append(EVM.addressFromString(hex))
        }

        let configs: {Type: {Type: {Type: {String: AnyStruct}}}} = {
                Type<@mUSDCStrategyComposer>(): {
                    Type<@mUSDCStrategy>(): {
                        initialCollateralType: {
                            "univ3FactoryEVMAddress": self.univ3FactoryEVMAddress,
                            "univ3RouterEVMAddress": self.univ3RouterEVMAddress,
                            "univ3QuoterEVMAddress": self.univ3QuoterEVMAddress,
                            "yieldTokenEVMAddress": self.yieldTokenEVMAddress,
                            "yieldToCollateralUniV3AddressPaths": {
                                initialCollateralType: swapAddressPath
                            },
                            "yieldToCollateralUniV3FeePaths": {
                                initialCollateralType: recollateralizationUniV3FeePath
                            }
                        }
                    }
                },
                Type<@TracerStrategyComposer>(): {
                    Type<@TracerStrategy>(): {}
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
