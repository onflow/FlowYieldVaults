// standards
import "FungibleToken"
import "FlowToken"
// DeFiBlocks
import "DFBUtils"
import "DFB"
import "DFBv2"
import "SwapStack"
// Lending protocol
import "TidalProtocol"
// TidalYield platform
import "Tidal"
import "TidalYieldAutoBalancersV2"
// tokens
import "YieldToken"
import "MOET"
// mocks
import "MockOracle"
import "MockSwapper"

/// TidalYieldStrategiesV2
///
/// This contract defines high-precision Strategies using AutoBalancerV2 with UInt256 calculations.
/// It provides the same functionality as TidalYieldStrategies but with improved precision for
/// value tracking and rebalancing operations.
///
access(all) contract TidalYieldStrategiesV2 {

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// TracerStrategyV2 - High-precision version using AutoBalancerV2
    access(all) resource TracerStrategyV2 : Tidal.Strategy {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) let position: TidalProtocol.Position
        access(self) var sink: {DFB.Sink}
        access(self) var source: {DFB.Source}

        init(id: DFB.UniqueIdentifier, collateralType: Type, position: TidalProtocol.Position) {
            self.uniqueID = id
            self.position = position
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
        }

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return { self.sink.getSinkType(): true }
        }

        access(all) fun availableBalance(ofToken: Type): UFix64 {
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
        }

        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.sink.depositCapacity(from: from)
        }

        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            if ofToken != self.source.getSourceType() {
                return <- DFBUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }

        access(contract) fun burnCallback() {
            TidalYieldAutoBalancersV2._cleanupAutoBalancer(id: self.id()!)
        }
    }

    /// TracerStrategyComposerV2 - Creates strategies with high-precision AutoBalancerV2
    access(all) resource TracerStrategyComposerV2 : Tidal.StrategyComposer {
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            return { Type<@TracerStrategyV2>(): true }
        }

        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }

        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }

        /// Creates a strategy using high-precision AutoBalancerV2
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DFB.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{Tidal.Strategy} {
            // Use the same oracle for all components
            let oracle = MockOracle.PriceOracle()

            // Token types
            let collateralType = withFunds.getType()
            let yieldTokenType = Type<@YieldToken.Vault>()
            let moetTokenType = Type<@MOET.Vault>()
            let flowTokenType = Type<@FlowToken.Vault>()

            // Create high-precision AutoBalancerV2
            let autoBalancer = TidalYieldAutoBalancersV2._initNewAutoBalancer(
                oracle: oracle,
                vaultType: yieldTokenType,
                lowerThreshold: 0.95,       // 5% below value threshold
                upperThreshold: 1.05,       // 5% above value threshold
                rebalanceSink: nil,
                rebalanceSource: nil,
                uniqueID: uniqueID
            )

            // Get sink and source from AutoBalancerV2
            let abaSink = autoBalancer.createBalancerSink() 
                ?? panic("Could not retrieve Sink from AutoBalancerV2 with id \(uniqueID.id)")
            let abaSource = autoBalancer.createBalancerSource() 
                ?? panic("Could not retrieve Source from AutoBalancerV2 with id \(uniqueID.id)")

            // Create swappers
            let moetToYieldSwapper = MockSwapper.Swapper(
                inVault: moetTokenType,
                outVault: yieldTokenType,
                uniqueID: uniqueID
            )
            let yieldToMoetSwapper = MockSwapper.Swapper(
                inVault: yieldTokenType,
                outVault: moetTokenType,
                uniqueID: uniqueID
            )

            // Create swap connectors
            let abaSwapSink = SwapStack.SwapSink(
                swapper: moetToYieldSwapper, 
                sink: abaSink, 
                uniqueID: uniqueID
            )
            let abaSwapSource = SwapStack.SwapSource(
                swapper: yieldToMoetSwapper, 
                source: abaSource, 
                uniqueID: uniqueID
            )

            // Open TidalProtocol position
            let position = TidalProtocol.openPosition(
                collateral: <-withFunds,
                issuanceSink: abaSwapSink,
                repaymentSource: abaSwapSource,
                pushToDrawDownSink: true
            )

            // Get position connectors
            let positionSink = position.createSinkWithOptions(
                type: collateralType, 
                pushToDrawDownSink: true
            )
            let positionSource = position.createSourceWithOptions(
                type: collateralType, 
                pullFromTopUpSource: true
            )

            // Create yield to flow swapper
            let yieldToFlowSwapper = MockSwapper.Swapper(
                inVault: yieldTokenType,
                outVault: flowTokenType,
                uniqueID: uniqueID
            )
            
            // Create position swap sink
            let positionSwapSink = SwapStack.SwapSink(
                swapper: yieldToFlowSwapper, 
                sink: positionSink, 
                uniqueID: uniqueID
            )

            // Set the AutoBalancer's rebalance sink
            autoBalancer.setSink(positionSwapSink)

            return <-create TracerStrategyV2(
                id: DFB.UniqueIdentifier(),
                collateralType: collateralType,
                position: position
            )
        }
    }

    /// StrategyComposerIssuer for V2 strategies
    access(all) resource StrategyComposerIssuer : Tidal.StrategyComposerIssuer {
        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { Type<@TracerStrategyComposerV2>(): true }
        }

        access(all) fun issueComposer(_ type: Type): @{Tidal.StrategyComposer} {
            switch type {
            case Type<@TracerStrategyComposerV2>():
                return <- create TracerStrategyComposerV2()
            default:
                panic("Unsupported StrategyComposer requested: \(type.identifier)")
            }
        }
    }

    init() {
        self.IssuerStoragePath = StoragePath(identifier: "TidalYieldStrategyComposerIssuerV2_\(self.account.address)")!
        self.account.storage.save(<-create StrategyComposerIssuer(), to: self.IssuerStoragePath)
    }
} 