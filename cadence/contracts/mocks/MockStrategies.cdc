// standards
import "FungibleToken"
import "FlowToken"
import "EVM"
// DeFiActions
import "DeFiActionsUtils"
import "DeFiActions"
import "SwapConnectors"
import "FungibleTokenConnectors"
// Lending protocol
import "FlowALPv0"
// FlowYieldVaults platform
import "FlowYieldVaultsClosedBeta"
import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancers"
// scheduler
import "FlowTransactionScheduler"
// tokens
import "YieldToken"
import "MOET"
// mocks
import "MockOracle"
import "MockSwapper"

/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// MockStrategies
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
access(all) contract MockStrategies {

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// This is the first Strategy implementation, wrapping a @FlowALPv0.Position along with its related Sink &
    /// Source. While this object is a simple wrapper for the top-level collateralized position, the true magic of the
    /// DeFiActions is in the stacking of the related connectors. This stacking logic can be found in the
    /// TracerStrategyComposer construct.
    access(all) resource TracerStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: @FlowALPv0.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(id: DeFiActions.UniqueIdentifier, collateralType: Type, position: @FlowALPv0.Position) {
            self.uniqueID = id
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
            self.position <-position
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
    access(all) resource TracerStrategyComposer : FlowYieldVaults.StrategyComposer {
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
        ): @{FlowYieldVaults.Strategy} {
            // this PriceOracle is mocked and will be shared by all components used in the TracerStrategy
            let oracle = MockOracle.PriceOracle()

            // assign token types

            let moetTokenType: Type = Type<@MOET.Vault>()
            let yieldTokenType = Type<@YieldToken.Vault>()
            // assign collateral & flow token types
            let collateralType = withFunds.getType()

            // Create recurring config for automatic rebalancing
            let recurringConfig = MockStrategies._createRecurringConfig(withID: uniqueID)

            // configure and AutoBalancer for this stack with native recurring scheduling
            let autoBalancer = FlowYieldVaultsAutoBalancers._initNewAutoBalancer(
                oracle: oracle,                 // used to determine value of deposits & when to rebalance
                vaultType: yieldTokenType,      // the type of Vault held by the AutoBalancer
                lowerThreshold: 0.95,           // set AutoBalancer to pull from rebalanceSource when balance is 5% below value of deposits
                upperThreshold: 1.05,           // set AutoBalancer to push to rebalanceSink when balance is 5% below value of deposits
                rebalanceSink: nil,             // nil on init - will be set once a PositionSink is available
                rebalanceSource: nil,           // nil on init - not set for TracerStrategy
                recurringConfig: recurringConfig, // enables native AutoBalancer self-scheduling
                uniqueID: uniqueID              // identifies AutoBalancer as part of this Strategy
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
            let poolCap = MockStrategies.account.storage.load<Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            ) ?? panic("Missing pool capability")

            let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

            let position <- poolRef.createPosition(
                funds: <-withFunds,
                issuanceSink: abaSwapSink,
                repaymentSource: abaSwapSource,
                pushToDrawDownSink: true
            )
            MockStrategies.account.storage.save(poolCap, to: FlowALPv0.PoolCapStoragePath)

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

            // Use the same uniqueID passed to createStrategy so Strategy.burnCallback
            // calls _cleanupAutoBalancer with the correct ID
            return <-create TracerStrategy(
                id: uniqueID,
                collateralType: collateralType,
                position: <- position
            )
        }
    }

    access(all) entitlement Configure

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since TracerStrategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowYieldVaults.StrategyComposerIssuer {
        /// { StrategyComposer Type: { Strategy Type: { Collateral Type: { String: AnyStruct } } } }
        access(all) let configs: {Type: {Type: {Type: {String: AnyStruct}}}}

        init(configs: {Type: {Type: {Type: {String: AnyStruct}}}}) {
            self.configs = configs
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return {
                Type<@TracerStrategyComposer>(): true
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
                assert(stratType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()),
                    message: "Invalid config key \(stratType.identifier) - not a FlowYieldVaults.Strategy Type")
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

    /// Creates an AutoBalancerRecurringConfig for scheduled rebalancing.
    /// The txnFunder uses the contract's FlowToken vault to pay for scheduling fees.
    access(self)
    fun _createRecurringConfig(withID: DeFiActions.UniqueIdentifier?): DeFiActions.AutoBalancerRecurringConfig {
        // Create txnFunder that can provide/accept FLOW for scheduling fees
        let txnFunder = self._createTxnFunder(withID: withID)

        return DeFiActions.AutoBalancerRecurringConfig(
            interval: 60 * 10,  // Rebalance every 10 minutes
            priority: FlowTransactionScheduler.Priority.Medium,
            executionEffort: 999,
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

    init() {
        self.IssuerStoragePath = StoragePath(identifier: "FlowYieldVaultsStrategyComposerIssuer_\(self.account.address)")!

        let initialCollateralType = Type<@FlowToken.Vault>()

        let configs: {Type: {Type: {Type: {String: AnyStruct}}}} = {
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
