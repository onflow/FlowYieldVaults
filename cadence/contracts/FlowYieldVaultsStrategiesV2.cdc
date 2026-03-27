// standards
import "Burner"
import "FungibleToken"
import "EVM"
// DeFiActions
import "DeFiActionsUtils"
import "DeFiActions"
import "AutoBalancers"
import "SwapConnectors"
import "FungibleTokenConnectors"
// amm integration
import "UniswapV3SwapConnectors"
import "ERC4626SwapConnectors"
import "MorphoERC4626SwapConnectors"
import "ERC4626Utils"
// Lending protocol
import "FlowALPv0"
// FlowYieldVaults platform
import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancersV1"
// scheduler
import "FlowTransactionScheduler"
// tokens
import "MOET"
// vm bridge
import "FlowEVMBridgeConfig"
// live oracles
import "ERC4626PriceOracles"

/// FlowYieldVaultsStrategiesV2
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
access(all) contract FlowYieldVaultsStrategiesV2 {

    access(all) let univ3FactoryEVMAddress: EVM.EVMAddress
    access(all) let univ3RouterEVMAddress: EVM.EVMAddress
    access(all) let univ3QuoterEVMAddress: EVM.EVMAddress

    /// Partitioned config map. Each key is a partition name; each value is a typed nested map keyed by
    /// strategy UniqueIdentifier ID (UInt64). Current partitions:
    ///   "closedPositions"            → {UInt64: Bool}
    access(contract) let config: {String: AnyStruct}

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// Emitted when a non-empty vault is destroyed because the swapper quote returned zero output,
    /// indicating the balance is too small to route (dust). Includes the quote as evidence of why
    /// the burn decision was made, to aid debugging of stale or misconfigured swapper paths.
    access(all) event DustBurned(
        tokenType: String,
        balance: UFix64,
        quoteInType: String,
        quoteOutType: String,
        quoteInAmount: UFix64,
        quoteOutAmount: UFix64,
        swapperType: String
    )

    /// Deprecated — replaced by SwapConnectors.SwapSource. Kept as a no-op to preserve
    /// contract upgrade compatibility (Cadence structs cannot be removed once deployed).
    access(all) struct BufferedSwapSource : DeFiActions.Source {
        access(self) let swapper: {DeFiActions.Swapper}
        access(self) let source: {DeFiActions.Source}
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            swapper: {DeFiActions.Swapper},
            source: {DeFiActions.Source},
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            self.swapper = swapper
            self.source = source
            self.uniqueID = uniqueID
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(type: self.getType(), id: self.id(), innerComponents: [])
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? { return self.uniqueID }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) { self.uniqueID = id }
        access(all) view fun getSourceType(): Type { return self.swapper.outType() }
        access(all) fun minimumAvailable(): UFix64 { return 0.0 }
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
        }
    }

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

    /// This strategy uses FUSDEV vault (Morpho ERC4626).
    /// Deposits collateral into a single FlowALP position, borrowing MOET as debt.
    /// MOET is swapped to PYUSD0 and deposited into the Morpho FUSDEV ERC4626 vault.
    /// Each strategy instance holds exactly one collateral type and one debt type (MOET).
    /// PYUSD0 (the FUSDEV vault's underlying asset) cannot be used as collateral.
    access(all) resource FUSDEVStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: @FlowALPv0.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(
            id: DeFiActions.UniqueIdentifier,
            collateralType: Type,
            position: @FlowALPv0.Position
        ) {
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
            if self._isPositionClosed() { return 0.0 }
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
        }
        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference.
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                from.getType() == self.sink.getSinkType():
                    "FUSDEVStrategy position only accepts \(self.sink.getSinkType().identifier) as collateral, got \(from.getType().identifier)"
            }
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
        /// Closes the underlying FlowALP position by preparing repayment funds and closing with them.
        ///
        /// This method:
        /// 1. Calculates debt amount from position
        /// 2. Creates external yield token source from AutoBalancer
        /// 3. Swaps yield tokens → MOET via stored swapper
        /// 4. Closes position with prepared MOET vault
        ///
        /// This approach eliminates circular dependencies by preparing all funds externally
        /// before calling the position's close method.
        ///
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            post {
                result.getType() == collateralType: "Withdraw Vault (\(result.getType().identifier)) is not of a requested collateral type (\(collateralType.identifier))"
            }

            // Step 1: Get debt amounts - returns {Type: UFix64} dictionary
            let debtsByType = self.position.getTotalDebt()

            // Enforce: one debt type per position
            assert(
                debtsByType.length <= 1,
                message: "FUSDEVStrategy position must have at most one debt type, found \(debtsByType.length)"
            )

            // Step 2: Calculate total debt amount
            var totalDebtAmount: UFix64 = 0.0
            for debtAmount in debtsByType.values {
                totalDebtAmount = totalDebtAmount + debtAmount
            }

            // Step 3: If no debt, close with empty sources array
            if totalDebtAmount == 0.0 {
                let resultVaults <- self.position.closePosition(
                    repaymentSources: []
                )
                // With one collateral type and no debt the pool returns at most one vault.
                // Zero vaults is possible when the collateral balance is dust that rounds down
                // to zero (e.g. drawDownSink had no capacity, or token reserves were empty).
                assert(
                    resultVaults.length <= 1,
                    message: "Expected 0 or 1 collateral vault from closePosition, got \(resultVaults.length)"
                )
                // Zero vaults: dust collateral rounded down to zero — return an empty vault
                if resultVaults.length == 0 {
                    destroy resultVaults
                    self._markPositionClosed()
                    return <- DeFiActionsUtils.getEmptyVault(collateralType)
                }
                var collateralVault <- resultVaults.removeFirst()
                destroy resultVaults
                self._markPositionClosed()
                return <- collateralVault
            }

            // Step 4: Create external yield token source from AutoBalancer
            let yieldTokenSource = FlowYieldVaultsAutoBalancersV1.createExternalSource(id: self.id()!)
                ?? panic("Could not create external source from AutoBalancer")

            // Step 5: Reconstruct yield→MOET swapper from stored CollateralConfig.
            let closeCollateralConfig = self._getStoredCollateralConfig(
                strategyType: Type<@FUSDEVStrategy>(),
                collateralType: collateralType
            ) ?? panic("No CollateralConfig for FUSDEVStrategy with \(collateralType.identifier)")
            let closeTokens = FlowYieldVaultsStrategiesV2._resolveTokenBundle(
                yieldTokenEVMAddress: closeCollateralConfig.yieldTokenEVMAddress
            )
            let yieldToMoetSwapper = self._buildYieldToDebtSwapper(
                tokens: closeTokens,
                uniqueID: self.uniqueID!
            )

            // Step 6: Pre-supplement from collateral if yield is insufficient to cover the full debt.
            //
            // The FUSDEV close path has a structural ~0.02% round-trip fee loss:
            //   Open:  MOET → PYUSD0 (UniV3 0.01%) → FUSDEV (ERC4626, free)
            //   Close: FUSDEV → PYUSD0 (ERC4626, free) → MOET (UniV3 0.01%)
            // In production, accrued yield more than covers this; with no accrued yield (e.g. in
            // tests, immediate open+close), the yield tokens convert back to slightly less MOET
            // than was borrowed. We handle this by pre-pulling a tiny amount of collateral from
            // self.source, swapping it to MOET, and depositing it into the position to reduce the
            // outstanding debt — BEFORE calling position.closePosition.
            //
            // This MUST be done before closePosition because the position is locked during close:
            // any attempt to pull from self.source inside a repaymentSource.withdrawAvailable call
            // would trigger "Reentrancy: position X is locked".
            let yieldAvail = yieldTokenSource.minimumAvailable()
            let expectedMOET = yieldAvail > 0.0
                ? yieldToMoetSwapper.quoteOut(forProvided: yieldAvail, reverse: false).outAmount
                : 0.0
            if expectedMOET < totalDebtAmount {
                let collateralToMoetSwapper = self._buildCollateralToDebtSwapper(
                    collateralConfig: closeCollateralConfig,
                    tokens: closeTokens,
                    collateralType: collateralType,
                    uniqueID: self.uniqueID!
                )
                let shortfall = totalDebtAmount - expectedMOET
                let quote = collateralToMoetSwapper.quoteIn(forDesired: shortfall, reverse: false)
                assert(quote.inAmount > 0.0,
                    message: "Pre-supplement: collateral→MOET quote returned zero input for non-zero shortfall — swapper misconfigured")
                let extraCollateral <- self.source.withdrawAvailable(maxAmount: quote.inAmount)
                assert(extraCollateral.balance > 0.0,
                    message: "Pre-supplement: no collateral available to cover shortfall of \(shortfall) MOET")
                let extraMOET <- collateralToMoetSwapper.swap(quote: quote, inVault: <-extraCollateral)
                assert(extraMOET.balance >= shortfall,
                    message: "Pre-supplement: collateral→MOET swap produced less than shortfall: got \(extraMOET.balance), need \(shortfall)")
                self.position.deposit(from: <-extraMOET)
            }

            // Step 7: Create a SwapSource that converts yield tokens → MOET for debt repayment.
            // Step 6's pre-supplement ensures remaining debt ≤ yield value, so SwapSource will
            // use quoteIn(remainingDebt) and pull only the shares needed — not the full balance.
            let moetSource = SwapConnectors.SwapSource(
                swapper: yieldToMoetSwapper,
                source: yieldTokenSource,
                uniqueID: self.copyID()
            )

            // Step 8: Close position - pool pulls up to the (now pre-reduced) debt from moetSource
            let resultVaults <- self.position.closePosition(repaymentSources: [moetSource])

            // With one collateral type and one debt type, the pool returns at most two vaults:
            // the collateral vault and optionally a MOET overpayment dust vault.
            // closePosition returns vaults in dict-iteration order (hash-based), so we cannot
            // assume the collateral vault is first. Find it by type and convert any non-collateral
            // vaults (MOET overpayment dust) back to collateral via reconstructed swapper.
            // Reconstruct MOET→YIELD→collateral from CollateralConfig.
            let debtToCollateralSwapper = self._buildDebtToCollateralSwapper(
                collateralConfig: closeCollateralConfig,
                tokens: closeTokens,
                collateralType: collateralType,
                uniqueID: self.uniqueID!
            )

            var collateralVault <- DeFiActionsUtils.getEmptyVault(collateralType)
            while resultVaults.length > 0 {
                let v <- resultVaults.removeFirst()
                if v.getType() == collateralType {
                    collateralVault.deposit(from: <-v)
                } else if v.balance == 0.0 {
                    // destroy empty vault
                    Burner.burn(<-v)
                } else {
                    // Quote first — if dust is too small to route, destroy it
                    let quote = debtToCollateralSwapper.quoteOut(forProvided: v.balance, reverse: false)
                    if quote.outAmount > 0.0 {
                        let swapped <- debtToCollateralSwapper.swap(quote: quote, inVault: <-v)
                        collateralVault.deposit(from: <-swapped)
                    } else {
                        emit DustBurned(
                            tokenType: v.getType().identifier,
                            balance: v.balance,
                            quoteInType: quote.inType.identifier,
                            quoteOutType: quote.outType.identifier,
                            quoteInAmount: quote.inAmount,
                            quoteOutAmount: quote.outAmount,
                            swapperType: debtToCollateralSwapper.getType().identifier
                        )
                        Burner.burn(<-v)
                    }
                }
            }

            destroy resultVaults
            self._markPositionClosed()
            return <- collateralVault
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancersV1._cleanupAutoBalancer(id: self.id()!)
            self._cleanupPositionClosed()
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

        /* ===========================
           closePosition helpers
           =========================== */

        access(self) fun _getStoredCollateralConfig(
            strategyType: Type,
            collateralType: Type
        ): CollateralConfig? {
            let issuer = FlowYieldVaultsStrategiesV2.account.storage.borrow<
                &FlowYieldVaultsStrategiesV2.StrategyComposerIssuer
            >(from: FlowYieldVaultsStrategiesV2.IssuerStoragePath)
            if issuer == nil { return nil }
            return issuer!.getCollateralConfig(strategyType: strategyType, collateralType: collateralType)
        }

        /// Builds a YIELD→MOET MultiSwapper (AMM direct + ERC4626 redeem path).
        access(self) fun _buildYieldToDebtSwapper(
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            let yieldToDebtAMM = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: [tokens.yieldTokenEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [100],
                inVault: tokens.yieldTokenType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )
            let yieldToUnderlying = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: true
            )
            let underlyingToDebt = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: [tokens.underlying4626AssetEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [100],
                inVault: tokens.underlying4626AssetType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )
            let seq = SwapConnectors.SequentialSwapper(
                swappers: [yieldToUnderlying, underlyingToDebt],
                uniqueID: uniqueID
            )
            return SwapConnectors.MultiSwapper(
                inVault: tokens.yieldTokenType,
                outVault: tokens.moetTokenType,
                swappers: [yieldToDebtAMM, seq],
                uniqueID: uniqueID
            )
        }

        /// Builds a collateral→MOET UniV3 swapper from CollateralConfig.
        /// Derives the path by reversing yieldToCollateralUniV3AddressPath[1..] (skipping the
        /// yield token) and appending MOET, preserving all intermediate hops.
        /// e.g. [FUSDEV, PYUSD0, WETH, WBTC] → [WBTC, WETH, PYUSD0, MOET]
        access(self) fun _buildCollateralToDebtSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            let yieldToCollPath = collateralConfig.yieldToCollateralUniV3AddressPath
            let yieldToCollFees = collateralConfig.yieldToCollateralUniV3FeePath
            assert(yieldToCollPath.length >= 2, message: "yieldToCollateral path requires at least yield and collateral tokens, got \(yieldToCollPath.length)")
            // Build reversed path: iterate yieldToCollPath from last down to index 1 (skip yield token at 0),
            // then append MOET. e.g. [FUSDEV, PYUSD0, WETH, WBTC] → [WBTC, WETH, PYUSD0] + MOET
            var collToDebtPath: [EVM.EVMAddress] = []
            var collToDebtFees: [UInt32] = []
            for i in InclusiveRange(yieldToCollPath.length - 1, 1, step: -1) {
                collToDebtPath.append(yieldToCollPath[i])
            }
            collToDebtPath.append(tokens.moetTokenEVMAddress)
            // Build reversed fees: iterate from last down to index 1 (skip yield→underlying fee at 0),
            // then append PYUSD0→MOET fee (100). e.g. [100, 3000, 3000] → [3000, 3000] + 100
            for i in InclusiveRange(yieldToCollFees.length - 1, 1, step: -1) {
                collToDebtFees.append(yieldToCollFees[i])
            }
            collToDebtFees.append(UInt32(100))
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: collToDebtPath,
                feePath: collToDebtFees,
                inVault: collateralType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )
        }

        /// Builds a MOET→collateral SequentialSwapper for dust handling: MOET→YIELD→collateral.
        access(self) fun _buildDebtToCollateralSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.SequentialSwapper {
            let debtToYieldAMM = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: [tokens.moetTokenEVMAddress, tokens.yieldTokenEVMAddress],
                feePath: [100],
                inVault: tokens.moetTokenType,
                outVault: tokens.yieldTokenType,
                uniqueID: uniqueID
            )
            let yieldToCollateral = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: collateralConfig.yieldToCollateralUniV3AddressPath,
                feePath: collateralConfig.yieldToCollateralUniV3FeePath,
                inVault: tokens.yieldTokenType,
                outVault: collateralType,
                uniqueID: uniqueID
            )
            return SwapConnectors.SequentialSwapper(
                swappers: [debtToYieldAMM, yieldToCollateral],
                uniqueID: uniqueID
            )
        }

        access(self) view fun _isPositionClosed(): Bool {
            if let id = self.uniqueID {
                let partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
                return partition[id.id] ?? false
            }
            return false
        }

        access(self) fun _markPositionClosed() {
            if let id = self.uniqueID {
                var partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
                partition[id.id] = true
                FlowYieldVaultsStrategiesV2.config["closedPositions"] = partition
            }
        }

        access(self) fun _cleanupPositionClosed() {
            if let id = self.uniqueID {
                var partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
                partition.remove(key: id.id)
                FlowYieldVaultsStrategiesV2.config["closedPositions"] = partition
            }
        }
    }

    access(all) struct TokenBundle {
        /// The MOET token type (the pool's borrowable token)
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

    // @deprecated
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

    /// Returned bundle for stored AutoBalancer interactions (reference + caps)
    access(all) struct AutoBalancerIO_v2 {
        access(all) let autoBalancer:
            auth(AutoBalancers.Auto, AutoBalancers.Set, AutoBalancers.Get, AutoBalancers.Schedule, FungibleToken.Withdraw)
            &AutoBalancers.AutoBalancer

        access(all) let sink: {DeFiActions.Sink}
        access(all) let source: {DeFiActions.Source}

        init(
            autoBalancer: auth(AutoBalancers.Auto, AutoBalancers.Set, AutoBalancers.Get, AutoBalancers.Schedule, FungibleToken.Withdraw) &AutoBalancers.AutoBalancer,
            sink: {DeFiActions.Sink},
            source: {DeFiActions.Source}
        ) {
            self.sink = sink
            self.source = source
            self.autoBalancer = autoBalancer
        }
    }

    /* ===========================
       Contract-level shared infrastructure
       =========================== */

    /// Gets the Pool's default token type (the borrowable token)
    access(self) fun _getPoolDefaultToken(): Type {
        let poolCap = FlowYieldVaultsStrategiesV2.account.storage.copy<
            Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>
        >(from: FlowALPv0.PoolCapStoragePath)
            ?? panic("Missing or invalid pool capability")
        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")
        return poolRef.getDefaultToken()
    }

    /// Resolves the full token bundle for a strategy given the ERC4626 yield vault address.
    /// The MOET token is always the pool's default token.
    access(self) fun _resolveTokenBundle(yieldTokenEVMAddress: EVM.EVMAddress): FlowYieldVaultsStrategiesV2.TokenBundle {
        let moetTokenType = FlowYieldVaultsStrategiesV2._getPoolDefaultToken()
        let moetTokenEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetTokenType)
            ?? panic("Token Vault type \(moetTokenType.identifier) has not yet been registered with the VMbridge")

        let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: yieldTokenEVMAddress)
            ?? panic("Could not retrieve the VM Bridge associated Type for the yield token address \(yieldTokenEVMAddress.toString())")

        let underlying4626AssetEVMAddress = ERC4626Utils.underlyingAssetEVMAddress(vault: yieldTokenEVMAddress)
            ?? panic("Could not get the underlying asset's EVM address for ERC4626Vault \(yieldTokenEVMAddress.toString())")
        let underlying4626AssetType = FlowEVMBridgeConfig.getTypeAssociated(with: underlying4626AssetEVMAddress)
            ?? panic("Could not retrieve the VM Bridge associated Type for the ERC4626 underlying asset \(underlying4626AssetEVMAddress.toString())")

        return FlowYieldVaultsStrategiesV2.TokenBundle(
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

    access(self) fun _initAutoBalancerAndIO(
        oracle: {DeFiActions.PriceOracle},
        yieldTokenType: Type,
        recurringConfig: AutoBalancers.AutoBalancerRecurringConfig?,
        uniqueID: DeFiActions.UniqueIdentifier
    ): FlowYieldVaultsStrategiesV2.AutoBalancerIO_v2 {
        let autoBalancerRef =
            FlowYieldVaultsAutoBalancersV1._initNewAutoBalancer(
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

        return FlowYieldVaultsStrategiesV2.AutoBalancerIO_v2(
            autoBalancer: autoBalancerRef,
            sink: sink,
            source: source
        )
    }

    access(self) fun _openCreditPosition(
        funds: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}
    ): @FlowALPv0.Position {
        let poolCap = FlowYieldVaultsStrategiesV2.account.storage.copy<
            Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>
        >(from: FlowALPv0.PoolCapStoragePath)
            ?? panic("Missing or invalid pool capability")

        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

        let position <- poolRef.createPosition(
            funds: <-funds,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: true
        )

        return <-position
    }

    /// This StrategyComposer builds a Strategy that uses ERC4626 and MorphoERC4626 vaults.
    /// Only handles FUSDEVStrategy (Morpho-based strategies that require UniV3 swap paths).
    access(all) resource MorphoERC4626StrategyComposer : FlowYieldVaults.StrategyComposer {
        /// { Strategy Type: { Collateral Type: CollateralConfig } }
        access(self) let config: {Type: {Type: CollateralConfig}}

        init(_ config: {Type: {Type: CollateralConfig}}) {
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
            if let strategyConfig = self.config[forStrategy] {
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
            pre {
                self.config[type] != nil: "Unsupported strategy type \(type.identifier)"
                self.config[type]!.length > 0: "No collateral configured for strategy type \(type.identifier)"
            }
            let collateralType = withFunds.getType()

            let collateralConfig = self._getCollateralConfig(
                strategyType: type,
                collateralType: collateralType
            )

            let tokens = FlowYieldVaultsStrategiesV2._resolveTokenBundle(
                yieldTokenEVMAddress: collateralConfig.yieldTokenEVMAddress
            )

            // Oracle used by AutoBalancer (tracks NAV of ERC4626 vault)
            let yieldTokenOracle = FlowYieldVaultsStrategiesV2._createYieldTokenOracle(
                yieldTokenEVMAddress: tokens.yieldTokenEVMAddress,
                underlyingAssetType: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )

            // Create recurring config for automatic rebalancing
            let recurringConfig = FlowYieldVaultsStrategiesV2._createRecurringConfig(withID: uniqueID)

            // Create/store/publish/register AutoBalancer (returns authorized ref)
            let balancerIO = FlowYieldVaultsStrategiesV2._initAutoBalancerAndIO(
                oracle: yieldTokenOracle,
                yieldTokenType: tokens.yieldTokenType,
                recurringConfig: recurringConfig,
                uniqueID: uniqueID
            )

            switch type {

            // -----------------------------------------------------------------------
            // FUSDEVStrategy: borrows MOET from the FlowALP position, swaps to FUSDEV
            // -----------------------------------------------------------------------
            case Type<@FUSDEVStrategy>():
                // Swappers: MOET <-> YIELD
                let debtToYieldSwapper = self._createDebtToYieldSwapper(tokens: tokens, uniqueID: uniqueID)
                let yieldToDebtSwapper = self._createYieldToDebtSwapper(tokens: tokens, uniqueID: uniqueID)

                // AutoBalancer-directed swap IO
                let abaSwapSink = SwapConnectors.SwapSink(
                    swapper: debtToYieldSwapper,
                    sink: balancerIO.sink,
                    uniqueID: uniqueID
                )
                let abaSwapSource = SwapConnectors.SwapSource(
                    swapper: yieldToDebtSwapper,
                    source: balancerIO.source,
                    uniqueID: uniqueID
                )

                // --- Standard path (WBTC, WETH, WFLOW — directly supported by FlowALP) ---

                // Open FlowALPv0 position
                let position <- FlowYieldVaultsStrategiesV2._openCreditPosition(
                    funds: <-withFunds,
                    issuanceSink: abaSwapSink,
                    repaymentSource: abaSwapSource
                )

                // Position Sink/Source for collateral rebalancing
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

                // pullFromTopUpSource: false ensures Position maintains health buffer
                let positionSource = position.createSourceWithOptions(
                    type: collateralType,
                    pullFromTopUpSource: false
                )

                // Collateral -> Yield swapper for AutoBalancer deficit recovery
                let collateralToYieldSwapper = self._createCollateralToYieldSwapper(
                    collateralConfig: collateralConfig,
                    yieldTokenEVMAddress: tokens.yieldTokenEVMAddress,
                    yieldTokenType: tokens.yieldTokenType,
                    collateralType: collateralType,
                    uniqueID: uniqueID
                )

                let positionSwapSource = SwapConnectors.SwapSource(
                    swapper: collateralToYieldSwapper,
                    source: positionSource,
                    uniqueID: uniqueID
                )

                balancerIO.autoBalancer.setSink(positionSwapSink, updateSinkID: true)
                balancerIO.autoBalancer.setSource(positionSwapSource, updateSourceID: true)

                return <-create FUSDEVStrategy(
                    id: uniqueID,
                    collateralType: collateralType,
                    position: <-position
                )

            default:
                panic("Unsupported strategy type \(type.identifier)")
            }
        }

        /* ===========================
           Helpers
           =========================== */

        access(self) fun _getCollateralConfig(
            strategyType: Type,
            collateralType: Type
        ): FlowYieldVaultsStrategiesV2.CollateralConfig {
            let strategyConfig = self.config[strategyType]
                ?? panic(
                    "Could not find a config for Strategy \(strategyType.identifier) initialized with \(collateralType.identifier)"
                )

            return strategyConfig[collateralType]
                ?? panic("Could not find config for collateral \(collateralType.identifier)")
        }

        access(self) fun _createUniV3Swapper(
            tokenPath: [EVM.EVMAddress],
            feePath: [UInt32],
            inVault: Type,
            outVault: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            return UniswapV3SwapConnectors.Swapper(
                factoryAddress: FlowYieldVaultsStrategiesV2.univ3FactoryEVMAddress,
                routerAddress: FlowYieldVaultsStrategiesV2.univ3RouterEVMAddress,
                quoterAddress: FlowYieldVaultsStrategiesV2.univ3QuoterEVMAddress,
                tokenPath: tokenPath,
                feePath: feePath,
                inVault: inVault,
                outVault: outVault,
                coaCapability: FlowYieldVaultsStrategiesV2._getCOACapability(),
                uniqueID: uniqueID
            )
        }

        access(self) fun _createDebtToYieldSwapper(
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            // Direct MOET -> YIELD via AMM
            let debtToYieldAMM = self._createUniV3Swapper(
                tokenPath: [tokens.moetTokenEVMAddress, tokens.yieldTokenEVMAddress],
                feePath: [100],
                inVault: tokens.moetTokenType,
                outVault: tokens.yieldTokenType,
                uniqueID: uniqueID
            )

            // MOET -> UNDERLYING via AMM
            let debtToUnderlying = self._createUniV3Swapper(
                tokenPath: [tokens.moetTokenEVMAddress, tokens.underlying4626AssetEVMAddress],
                feePath: [100],
                inVault: tokens.moetTokenType,
                outVault: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )

            // UNDERLYING -> YIELD via Morpho ERC4626 vault deposit
            let underlyingTo4626 = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: false
            )

            let seq = SwapConnectors.SequentialSwapper(
                swappers: [debtToUnderlying, underlyingTo4626],
                uniqueID: uniqueID
            )

            return SwapConnectors.MultiSwapper(
                inVault: tokens.moetTokenType,
                outVault: tokens.yieldTokenType,
                swappers: [debtToYieldAMM, seq],
                uniqueID: uniqueID
            )
        }

        access(self) fun _createYieldToDebtSwapper(
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            // Direct YIELD -> MOET via AMM
            let yieldToDebtAMM = self._createUniV3Swapper(
                tokenPath: [tokens.yieldTokenEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [100],
                inVault: tokens.yieldTokenType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )

            // YIELD -> UNDERLYING redeem via MorphoERC4626 vault
            let yieldToUnderlying = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: true
            )
            // UNDERLYING -> MOET via AMM
            let underlyingToDebt = self._createUniV3Swapper(
                tokenPath: [tokens.underlying4626AssetEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [100],
                inVault: tokens.underlying4626AssetType,
                outVault: tokens.moetTokenType,
                uniqueID: uniqueID
            )

            let seq = SwapConnectors.SequentialSwapper(
                swappers: [yieldToUnderlying, underlyingToDebt],
                uniqueID: uniqueID
            )

            return SwapConnectors.MultiSwapper(
                inVault: tokens.yieldTokenType,
                outVault: tokens.moetTokenType,
                swappers: [yieldToDebtAMM, seq],
                uniqueID: uniqueID
            )
        }

        access(self) fun _createYieldToCollateralSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
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

        /// Creates a Collateral -> Yield token swapper using UniswapV3
        /// This is the REVERSE of _createYieldToCollateralSwapper
        /// Used by AutoBalancer to pull collateral from Position and swap to yield tokens
        ///
        access(self) fun _createCollateralToYieldSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldTokenType: Type,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            // Reverse the swap path: collateral -> yield (opposite of yield -> collateral)
            let forwardPath = collateralConfig.yieldToCollateralUniV3AddressPath
            let reversedTokenPath = forwardPath.reverse()

            // Reverse the fee path as well
            let forwardFees = collateralConfig.yieldToCollateralUniV3FeePath
            let reversedFeePath = forwardFees.reverse()

            // Verify the reversed path starts with collateral (ends with yield)
            assert(
                reversedTokenPath[reversedTokenPath.length - 1].equals(yieldTokenEVMAddress),
                message: "Reversed path must end with yield token \(yieldTokenEVMAddress.toString())"
            )

            return self._createUniV3Swapper(
                tokenPath: reversedTokenPath,
                feePath: reversedFeePath,
                inVault: collateralType,     // ← Input is collateral
                outVault: yieldTokenType,    // ← Output is yield token
                uniqueID: uniqueID
            )
        }

        /// Creates a Collateral → Debt (MOET) swapper using UniswapV3.
        /// Path: collateral → underlying (PYUSD0) → MOET
        ///
        /// The fee for collateral→underlying is the last fee in yieldToCollateral (reversed),
        /// and the fee for underlying→MOET is fixed at 100 (0.01%, matching yieldToDebtSwapper).
        /// Stored and used by FUSDEVStrategy.closePosition to pre-reduce position debt from
        /// collateral when yield tokens alone cannot cover the full outstanding MOET debt.
        ///
        access(self) fun _createCollateralToDebtSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            let yieldToCollPath = collateralConfig.yieldToCollateralUniV3AddressPath
            let yieldToCollFees = collateralConfig.yieldToCollateralUniV3FeePath

            // collateral EVM address = last element of yieldToCollateral path
            // underlying (PYUSD0) EVM address = second element of yieldToCollateral path
            assert(yieldToCollPath.length >= 2, message: "yieldToCollateral path requires at least yield and collateral tokens, got \(yieldToCollPath.length)")
            let collateralEVMAddress = yieldToCollPath[yieldToCollPath.length - 1]
            let underlyingEVMAddress = tokens.underlying4626AssetEVMAddress

            // fee[0] = collateral→underlying = last fee in yieldToCollateral (reversed)
            // fee[1] = underlying→MOET = 100 (0.01%, matching _createYieldToDebtSwapper)
            let collateralToUnderlyingFee = yieldToCollFees[yieldToCollFees.length - 1]
            let underlyingToDebtFee: UInt32 = 100

            return self._createUniV3Swapper(
                tokenPath: [collateralEVMAddress, underlyingEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [collateralToUnderlyingFee, underlyingToDebtFee],
                inVault: collateralType,
                outVault: tokens.moetTokenType,
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
        /// { Composer Type: { Strategy Type: { Collateral Type: CollateralConfig } } }
        /// Used by MorphoERC4626StrategyComposer.
        access(all) var configs: {Type: {Type: {Type: CollateralConfig}}}

        init(configs: {Type: {Type: {Type: CollateralConfig}}}) {
            self.configs = configs
        }

        access(all) view fun hasConfig(
            composer: Type,
            strategy: Type,
            collateral: Type
        ): Bool {
            if let composerPartition = self.configs[composer] {
                if let stratPartition = composerPartition[strategy] {
                    if stratPartition[collateral] != nil { return true }
                }
            }
            return false
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return {
                Type<@MorphoERC4626StrategyComposer>(): true
            }
        }

        /// Returns CollateralConfig for the given strategy+collateral, by value (not reference).
        /// Called from contract-level _getStoredCollateralConfig to avoid reference-chain issues.
        access(all) fun getCollateralConfig(
            strategyType: Type,
            collateralType: Type
        ): CollateralConfig? {
            let composerType = Type<@MorphoERC4626StrategyComposer>()
            if let p0 = self.configs[composerType] {
                if let p1 = p0[strategyType] {
                    return p1[collateralType]
                }
            }
            return nil
        }

        access(self) view fun isSupportedComposer(_ type: Type): Bool {
            return type == Type<@MorphoERC4626StrategyComposer>()
        }

        access(all) fun issueComposer(_ type: Type): @{FlowYieldVaults.StrategyComposer} {
            pre {
                self.isSupportedComposer(type): "Unsupported StrategyComposer \(type.identifier) requested"
            }
            switch type {
            case Type<@MorphoERC4626StrategyComposer>():
                return <- create MorphoERC4626StrategyComposer(
                    self.configs[type] ?? panic("No config registered for \(type.identifier)")
                )
            default:
                panic("Unsupported StrategyComposer \(type.identifier) requested")
            }
        }

        /// Merges new CollateralConfig entries into the MorphoERC4626StrategyComposer config.
        access(Configure)
        fun upsertMorphoConfig(
            config: {Type: {Type: FlowYieldVaultsStrategiesV2.CollateralConfig}}
        ) {
            for stratType in config.keys {
                assert(stratType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()),
                    message: "Invalid config key \(stratType.identifier) - not a FlowYieldVaults.Strategy Type")
                for collateralType in config[stratType]!.keys {
                    assert(collateralType.isSubtype(of: Type<@{FungibleToken.Vault}>()),
                        message: "Invalid config key at config[\(stratType.identifier)] - \(collateralType.identifier) is not a FungibleToken.Vault")
                }
            }

            let composerType = Type<@MorphoERC4626StrategyComposer>()
            var composerPartition = self.configs[composerType] ?? {}
            for stratType in config.keys {
                var stratPartition: {Type: CollateralConfig} = composerPartition[stratType] ?? {}
                let newPerCollateral = config[stratType]!
                for collateralType in newPerCollateral.keys {
                    stratPartition[collateralType] = newPerCollateral[collateralType]!
                }
                composerPartition[stratType] = stratPartition
            }
            self.configs[composerType] = composerPartition
        }

        access(Configure) fun addOrUpdateMorphoCollateralConfig(
            strategyType: Type,
            collateralVaultType: Type,
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldToCollateralAddressPath: [EVM.EVMAddress],
            yieldToCollateralFeePath: [UInt32]
        ) {
            pre {
                strategyType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()):
                    "Strategy type \(strategyType.identifier) is not a FlowYieldVaults.Strategy"
                collateralVaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                    "Collateral type \(collateralVaultType.identifier) is not a FungibleToken.Vault"
            }

            let base = FlowYieldVaultsStrategiesV2.makeCollateralConfig(
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                yieldToCollateralAddressPath: yieldToCollateralAddressPath,
                yieldToCollateralFeePath: yieldToCollateralFeePath
            )
            self.upsertMorphoConfig(config: { strategyType: { collateralVaultType: base } })
        }

        access(Configure) fun purgeConfig() {
            self.configs = {
                Type<@MorphoERC4626StrategyComposer>(): {
                    Type<@FUSDEVStrategy>(): {} as {Type: CollateralConfig}
                }
            }
        }
    }

    /// Returns the COA capability for this account
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
    fun _createRecurringConfig(withID: DeFiActions.UniqueIdentifier?): AutoBalancers.AutoBalancerRecurringConfig {
        // Create txnFunder that can provide/accept FLOW for scheduling fees
        let txnFunder = self._createTxnFunder(withID: withID)

        return AutoBalancers.AutoBalancerRecurringConfig(
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

    /// Builds a UniswapV3 swapper. Shared by FUSDEVStrategy and syWFLOWvStrategy closePosition helpers.
    access(self) fun _buildUniV3Swapper(
        tokenPath: [EVM.EVMAddress],
        feePath: [UInt32],
        inVault: Type,
        outVault: Type,
        uniqueID: DeFiActions.UniqueIdentifier
    ): UniswapV3SwapConnectors.Swapper {
        return UniswapV3SwapConnectors.Swapper(
            factoryAddress: FlowYieldVaultsStrategiesV2.univ3FactoryEVMAddress,
            routerAddress:  FlowYieldVaultsStrategiesV2.univ3RouterEVMAddress,
            quoterAddress:  FlowYieldVaultsStrategiesV2.univ3QuoterEVMAddress,
            tokenPath: tokenPath,
            feePath: feePath,
            inVault: inVault,
            outVault: outVault,
            coaCapability: FlowYieldVaultsStrategiesV2._getCOACapability(),
            uniqueID: uniqueID
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
        self.IssuerStoragePath = StoragePath(identifier: "FlowYieldVaultsStrategyV2ComposerIssuer_\(self.account.address)")!
        self.config = {}

        let moetType = Type<@MOET.Vault>()
        if FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>()) == nil {
            panic("Could not find EVM address for \(moetType.identifier) - ensure the asset is onboarded to the VM Bridge")
        }

        let issuer <- create StrategyComposerIssuer(
            configs: {
                Type<@MorphoERC4626StrategyComposer>(): {
                    Type<@FUSDEVStrategy>(): {} as {Type: CollateralConfig}
                }
            }
        )
        self.account.storage.save(<-issuer, to: self.IssuerStoragePath)

        // TODO: this is temporary until we have a better way to pass user's COAs to inner connectors
        // create a COA in this account
        if self.account.storage.type(at: /storage/evm) == nil {
            self.account.storage.save(<-EVM.createCadenceOwnedAccount(), to: /storage/evm)
            let cap = self.account.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(/storage/evm)
            self.account.capabilities.publish(cap, at: /public/evm)
        }
    }
}
