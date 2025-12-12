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

/// PMStrategies
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
access(all) contract PMStrategies {

    access(all) var univ3FactoryEVMAddress: EVM.EVMAddress
    access(all) var univ3RouterEVMAddress: EVM.EVMAddress
    access(all) var univ3QuoterEVMAddress: EVM.EVMAddress

    access(all) var yieldTokenEVMAddress: EVM.EVMAddress
    access(all) var swapFeeTier: UInt32

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

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
            return FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: self.id()!)?.currentValue()! ?? 0.0 
            // @TODO: debug this call, why univ3 SwapSource returns wrong number
            //  with 100 FLOW it returns ~53 FLOW in balance
            // return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
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

    /// This StrategyComposer builds a syWFLOWvStrategy
    access(all) resource syWFLOWvStrategyComposer : FlowYieldVaults.StrategyComposer {
        init() {}

        /// Returns the Types of Strategies composed by this StrategyComposer
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            return { 
                Type<@syWFLOWvStrategy>(): true
            }
        }

        /// Returns the Vault types which can be used to initialize a given Strategy
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
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
            let flowTokenType = Type<@FlowToken.Vault>()

            // assign token types & associated EVM Addresses
            let wflowTokenEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: flowTokenType)
                ?? panic("Token Vault type \(flowTokenType.identifier) has not yet been registered with the VMbridge")
            let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: PMStrategies.yieldTokenEVMAddress)
                ?? panic("Could not retrieve the VM Bridge associated Type for the yield token address \(PMStrategies.yieldTokenEVMAddress.toString())")

            // create the oracle for the assets to be held in the AutoBalancer retrieving the NAV of the 4626 vault
            let yieldTokenOracle = ERC4626PriceOracles.PriceOracle(
                    vault: PMStrategies.yieldTokenEVMAddress,
                    asset: flowTokenType,
                    uniqueID: uniqueID
                )

            // Create recurring config for automatic rebalancing
            let recurringConfig = PMStrategies._createRecurringConfig(withID: uniqueID)

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
            let abaSource = autoBalancer.createBalancerSource() ?? panic("Could not retrieve Sink from AutoBalancer with id \(uniqueID.id)")

            // create WFLOW <-> YIELD swappers
            //
            // WFLOW -> YIELD - WFLOW can swap to YieldToken via two primary routes
            // - via AMM swap pairing WFLOW <-> YIELD
            // - via 4626 vault, swapping first to underlying asset then depositing to the 4626 vault
            // WFLOW -> YIELD high-level Swapper then contains
            //     - MultiSwapper aggregates across two sub-swappers
            //         - WFLOW -> YIELD (UniV3 Swapper)
            let wflowToYieldAMMSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: PMStrategies.univ3FactoryEVMAddress,
                    routerAddress: PMStrategies.univ3RouterEVMAddress,
                    quoterAddress: PMStrategies.univ3QuoterEVMAddress,
                    tokenPath: [wflowTokenEVMAddress, PMStrategies.yieldTokenEVMAddress],
                    feePath: [PMStrategies.swapFeeTier],
                    inVault: flowTokenType,
                    outVault: yieldTokenType,
                    coaCapability: PMStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )
            // Swap UNDERLYING -> YIELD via ERC4626 Vault
            let wflowTo4626Swapper = ERC4626SwapConnectors.Swapper(
                    asset: flowTokenType,
                    vault: PMStrategies.yieldTokenEVMAddress,
                    coa: PMStrategies._getCOACapability(),
                    feeSource: PMStrategies._createFeeSource(withID: uniqueID),
                    uniqueID: uniqueID
                )
            // Finally, add the two WFLOW -> YIELD swappers into an aggregate MultiSwapper
            let wflowToYieldSwapper = SwapConnectors.MultiSwapper(
                    inVault: flowTokenType,
                    outVault: yieldTokenType,
                    swappers: [wflowToYieldAMMSwapper, wflowTo4626Swapper],
                    uniqueID: uniqueID
                )

            // YIELD -> WFLOW 
            // - Targets the WFLOW <-> YIELD pool as the only route since withdraws from the ERC4626 Vault are async
            let yieldToWFLOWSwapper = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: PMStrategies.univ3FactoryEVMAddress,
                    routerAddress: PMStrategies.univ3RouterEVMAddress,
                    quoterAddress: PMStrategies.univ3QuoterEVMAddress,
                    tokenPath: [PMStrategies.yieldTokenEVMAddress, wflowTokenEVMAddress],
                    feePath: [PMStrategies.swapFeeTier],
                    inVault: yieldTokenType,
                    outVault: flowTokenType,
                    coaCapability: PMStrategies._getCOACapability(),
                    uniqueID: uniqueID
                )

            // init SwapSink directing swapped funds to AutoBalancer
            //
            // Swaps provided WFLOW to YIELD & deposits to the AutoBalancer
            let abaSwapSink = SwapConnectors.SwapSink(swapper: wflowToYieldSwapper, sink: abaSink, uniqueID: uniqueID)
            // Swaps YIELD & provides swapped WFLOW, sourcing YIELD from the AutoBalancer
            let abaSwapSource = SwapConnectors.SwapSource(swapper: yieldToWFLOWSwapper, source: abaSource, uniqueID: uniqueID)

            // set the AutoBalancer's rebalance Sink which it will use to deposit overflown value, recollateralizing
            // the position
            autoBalancer.setSink(abaSwapSink, updateSinkID: true)
            abaSwapSink.depositCapacity(from: &withFunds as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

            assert(withFunds.balance == 0.0, message: "Vault should be empty after depositing")
            destroy withFunds 

            // Use the same uniqueID passed to createStrategy so Strategy.burnCallback
            // calls _cleanupAutoBalancer with the correct ID
            return <-create syWFLOWvStrategy(
                id: uniqueID,
                sink: abaSwapSink,
                source: abaSwapSource
            )
        }
    }

    access(all) entitlement Configure

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since Strategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : FlowYieldVaults.StrategyComposerIssuer {
        init() {}

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { 
                Type<@syWFLOWvStrategyComposer>(): true
            }
        }
        access(all) fun issueComposer(_ type: Type): @{FlowYieldVaults.StrategyComposer} {
            pre {
                self.getSupportedComposers()[type] == true:
                "Unsupported StrategyComposer \(type.identifier) requested"
            }
            switch type {
            case Type<@syWFLOWvStrategyComposer>():
                return <- create syWFLOWvStrategyComposer()
            default:
                panic("Unsupported StrategyComposer \(type.identifier) requested")
            }
        }
        access(Configure)
        fun updateEVMAddresses(
            factory: String,
            router: String,
            quoter: String,
            yieldToken: String,
            swapFeeTier: UInt32
        ) {
            PMStrategies.univ3FactoryEVMAddress = EVM.addressFromString(factory)
            PMStrategies.univ3RouterEVMAddress  = EVM.addressFromString(router)
            PMStrategies.univ3QuoterEVMAddress  = EVM.addressFromString(quoter)
            PMStrategies.yieldTokenEVMAddress   = EVM.addressFromString(yieldToken)
            PMStrategies.swapFeeTier = swapFeeTier
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
        univ3QuoterEVMAddress: String,
        yieldTokenEVMAddress: String,
        swapFeeTier: UInt32
    ) {
        self.univ3FactoryEVMAddress = EVM.addressFromString(univ3FactoryEVMAddress)
        self.univ3RouterEVMAddress = EVM.addressFromString(univ3RouterEVMAddress)
        self.univ3QuoterEVMAddress = EVM.addressFromString(univ3QuoterEVMAddress)
        self.yieldTokenEVMAddress = EVM.addressFromString(yieldTokenEVMAddress)
        self.swapFeeTier = swapFeeTier

        self.IssuerStoragePath = StoragePath(identifier: "PMStrategiesComposerIssuer_\(self.account.address)")!

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
