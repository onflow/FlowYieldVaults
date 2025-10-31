// standards
import "FungibleToken"
import "FlowToken"
import "EVM"
// DeFiActions
import "DeFiActionsUtils"
import "DeFiActions"
import "SwapConnectors"
// Lending protocol
import "FlowALP"
// FlowVaults platform
import "FlowVaultsClosedBeta"
import "FlowVaults"
import "FlowVaultsAutoBalancers"
// tokens
import "YieldToken"
import "MOET"
// amm integration
import "UniswapV3SwapConnectors"
// vm bridge
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "FlowEVMBridge"
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

            // assign EVM token addresses & types

            let moetTokenType: Type = Type<@MOET.Vault>()
            let moetTokenEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetTokenType)
                ?? panic("MOET not registered in bridge")

            let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: TidalYieldStrategies.yieldTokenEVMAddress)
                ?? panic("YieldToken associated with EVM address \(TidalYieldStrategies.yieldTokenEVMAddress.toString()) not found in VM Bridge config")
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
            // TODO: Update to use UniswapV3SwapConnectors
            // let stableToYieldSwapper = MockSwapper.Swapper(
            //         inVault: moetTokenType,
            //         outVault: yieldTokenType,
            //         uniqueID: uniqueID
            //     )
            // TODO: consider how we're going to pass the user's COA capability to the Swapper
            let stableToYieldSwapper = UniswapV3SwapConnectors.Swapper(
                factoryAddress: TidalYieldStrategies.univ3FactoryEVMAddress,
                routerAddress: TidalYieldStrategies.univ3RouterEVMAddress,
                quoterAddress: TidalYieldStrategies.univ3QuoterEVMAddress,
                tokenPath: [moetTokenEVMAddress, TidalYieldStrategies.yieldTokenEVMAddress],
                feePath: [3000],
                inVault: moetTokenType,
                outVault: yieldTokenType,
                coaCapability: TidalYieldStrategies._getCOACapability(),
                uniqueID: uniqueID
            )
            // YieldToken -> Stable
            // TODO: Update to use UniswapV3SwapConnectors
            // let yieldToStableSwapper = MockSwapper.Swapper(
            //         inVault: yieldTokenType,
            //         outVault: moetTokenType,
            //         uniqueID: uniqueID
            //     )
            let yieldToStableSwapper = UniswapV3SwapConnectors.Swapper(
                factoryAddress: TidalYieldStrategies.univ3FactoryEVMAddress,
                routerAddress: TidalYieldStrategies.univ3RouterEVMAddress,
                quoterAddress: TidalYieldStrategies.univ3QuoterEVMAddress,
                tokenPath: [TidalYieldStrategies.yieldTokenEVMAddress, moetTokenEVMAddress],
                feePath: [3000],
                inVault: yieldTokenType,
                outVault: moetTokenType,
                coaCapability: TidalYieldStrategies._getCOACapability(),
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

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since TracerStrategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowVaults.StrategyComposerIssuer {
        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { Type<@TracerStrategyComposer>(): true }
        }
        access(all) fun issueComposer(_ type: Type): @{FlowVaults.StrategyComposer} {
            switch type {
            case Type<@TracerStrategyComposer>():
                return <- create TracerStrategyComposer()
            default:
                panic("Unsupported StrategyComposer requested: \(type.identifier)")
            }
        }
    }
    
    /// Returns the COA capability for this account
    /// TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
    access(self)
    fun _getCOACapability(): Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> {
        let coaCap = self.account.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)
        assert(coaCap.check(), message: "Could not issue COA capability")
        return coaCap
    }

    init(factoryAddress: String, routerAddress: String, quoterAddress: String, yieldTokenAddress: String) {
        self.univ3FactoryEVMAddress = EVM.addressFromString(factoryAddress)
        self.univ3RouterEVMAddress = EVM.addressFromString(routerAddress)
        self.univ3QuoterEVMAddress = EVM.addressFromString(quoterAddress)
        self.yieldTokenEVMAddress = EVM.addressFromString(yieldTokenAddress)

        self.IssuerStoragePath = StoragePath(identifier: "FlowVaultsStrategyComposerIssuer_\(self.account.address)")!

        self.account.storage.save(<-create StrategyComposerIssuer(), to: self.IssuerStoragePath)

        // TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
        // create a COA in this account
        if self.account.storage.type(at: /storage/evm) == nil {
            self.account.storage.save(<-EVM.createCadenceOwnedAccount(), to: /storage/evm)
            let cap = self.account.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(/storage/evm)
            self.account.capabilities.publish(cap, at: /public/evm)
        }
    }
}
