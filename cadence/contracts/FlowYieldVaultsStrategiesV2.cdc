// standards
import "Burner"
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
// Lending protocol
import "FlowALPv0"
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
    ///   "syWFLOWvDebtTokenTypes"     → {UInt64: Type}
    ///   "moreERC4626Configs"         → {Type: {Type: {Type: MoreERC4626CollateralConfig}}}
    ///   "moetPreswapConfigs"         → {Type: {Type: MoetPreswapConfig}}
    ///   "originalCollateralTypes"    → {UInt64: Type}
    access(contract) let config: {String: AnyStruct}

    /// Canonical StoragePath where the StrategyComposerIssuer should be stored
    access(all) let IssuerStoragePath: StoragePath

    /// A Source that converts yield tokens to debt tokens by pulling ALL available yield
    /// tokens from the wrapped source, rather than using quoteIn to limit the pull amount.
    ///
    /// This avoids ERC4626 rounding issues where quoteIn might underestimate required shares,
    /// causing the swap to return less than the requested debt amount. By pulling everything
    /// and swapping everything, the output is as large as the yield position allows.
    ///
    /// The caller is responsible for ensuring the yield tokens (after swapping) will cover the
    /// required debt — e.g. by pre-depositing supplemental MOET to reduce the position's debt
    /// before calling closePosition (see FUSDEVStrategy.closePosition step 6).
    access(all) struct BufferedSwapSource : DeFiActions.Source {
        access(self) let swapper: {DeFiActions.Swapper}
        access(self) let source: {DeFiActions.Source}
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            swapper: {DeFiActions.Swapper},
            source: {DeFiActions.Source},
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            pre {
                source.getSourceType() == swapper.inType():
                    "source type != swapper inType"
            }
            self.swapper = swapper
            self.source = source
            self.uniqueID = uniqueID
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: [
                    self.swapper.getComponentInfo(),
                    self.source.getComponentInfo()
                ]
            )
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? { return self.uniqueID }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) { self.uniqueID = id }
        access(all) view fun getSourceType(): Type { return self.swapper.outType() }
        access(all) fun minimumAvailable(): UFix64 {
            let avail = self.source.minimumAvailable()
            if avail == 0.0 { return 0.0 }
            return self.swapper.quoteOut(forProvided: avail, reverse: false).outAmount
        }
        /// Pulls ALL available yield tokens from the source and swaps them to the debt token.
        /// Ignores quoteIn — avoids ERC4626 rounding underestimates that would leave us short.
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if maxAmount == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
            }
            let availableIn = self.source.minimumAvailable()
            if availableIn == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
            }
            // Pull ALL available yield tokens (not quoteIn-limited)
            let sourceLiquidity <- self.source.withdrawAvailable(maxAmount: availableIn)
            if sourceLiquidity.balance == 0.0 {
                Burner.burn(<-sourceLiquidity)
                return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
            }
            return <- self.swapper.swap(quote: nil, inVault: <-sourceLiquidity)
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

    /// Configuration for pre-swapping a stablecoin collateral to MOET before depositing into
    /// FlowALP. Required when the collateral type is not directly supported by FlowALP (e.g.
    /// PYUSD0 must be swapped to MOET since FlowALP only supports MOET as its stablecoin).
    ///
    /// The path is collateral → MOET (e.g. [PYUSD0_addr, MOET_addr] for a 1-hop swap, or
    /// [PYUSD0_addr, WFLOW_addr, MOET_addr] for a 2-hop swap). The reverse (MOET→collateral)
    /// is derived automatically by reversing both arrays.
    access(all) struct MoetPreswapConfig {
        /// Full UniV3 swap path: collateral EVM address → ... → MOET EVM address.
        /// First element is the collateral, last element must be MOET.
        access(all) let collateralToMoetAddressPath: [EVM.EVMAddress]
        /// UniV3 fee tiers for each hop (length must equal addressPath.length - 1).
        access(all) let collateralToMoetFeePath: [UInt32]

        init(
            collateralToMoetAddressPath: [EVM.EVMAddress],
            collateralToMoetFeePath: [UInt32]
        ) {
            pre {
                collateralToMoetAddressPath.length > 1:
                    "MoetPreswapConfig: path must have at least 2 elements (collateral + MOET)"
                collateralToMoetFeePath.length == collateralToMoetAddressPath.length - 1:
                    "MoetPreswapConfig: fee path length must equal address path length - 1"
            }
            self.collateralToMoetAddressPath = collateralToMoetAddressPath
            self.collateralToMoetFeePath = collateralToMoetFeePath
        }
    }

    /// Collateral configuration for strategies that borrow the vault's underlying asset directly,
    /// using a standard ERC4626 deposit for the forward path (underlying → yield token) and a
    /// UniV3 AMM swap for the reverse path (yield token → underlying). This applies to "More"
    /// ERC4626 vaults that do not support synchronous redemptions via ERC4626 redeem().
    access(all) struct MoreERC4626CollateralConfig {
        access(all) let yieldTokenEVMAddress: EVM.EVMAddress
        /// UniV3 path for swapping yield token → underlying asset (used for debt repayment and
        /// AutoBalancer rebalancing). The path must start with the yield token EVM address.
        access(all) let yieldToUnderlyingUniV3AddressPath: [EVM.EVMAddress]
        access(all) let yieldToUnderlyingUniV3FeePath: [UInt32]
        /// UniV3 path for swapping debt token → collateral (used to convert overpayment dust
        /// returned by position.closePosition back into collateral). The path must start with
        /// the debt token EVM address and end with the collateral EVM address.
        access(all) let debtToCollateralUniV3AddressPath: [EVM.EVMAddress]
        access(all) let debtToCollateralUniV3FeePath: [UInt32]

        init(
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldToUnderlyingUniV3AddressPath: [EVM.EVMAddress],
            yieldToUnderlyingUniV3FeePath: [UInt32],
            debtToCollateralUniV3AddressPath: [EVM.EVMAddress],
            debtToCollateralUniV3FeePath: [UInt32]
        ) {
            self.yieldTokenEVMAddress = yieldTokenEVMAddress
            self.yieldToUnderlyingUniV3AddressPath = yieldToUnderlyingUniV3AddressPath
            self.yieldToUnderlyingUniV3FeePath = yieldToUnderlyingUniV3FeePath
            self.debtToCollateralUniV3AddressPath = debtToCollateralUniV3AddressPath
            self.debtToCollateralUniV3FeePath = debtToCollateralUniV3FeePath
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
            if FlowYieldVaultsStrategiesV2._isPositionClosed(self.uniqueID) { return 0.0 }
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
                    FlowYieldVaultsStrategiesV2._markPositionClosed(self.uniqueID)
                    return <- DeFiActionsUtils.getEmptyVault(collateralType)
                }
                var collateralVault <- resultVaults.removeFirst()
                destroy resultVaults
                FlowYieldVaultsStrategiesV2._markPositionClosed(self.uniqueID)
                return <- collateralVault
            }

            // Step 4: Create external yield token source from AutoBalancer
            let yieldTokenSource = FlowYieldVaultsAutoBalancers.createExternalSource(id: self.id()!)
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
                // Add 1% buffer to account for swap slippage/rounding in the collateral→MOET leg
                let buffered = shortfall + shortfall / 100.0
                let quote = collateralToMoetSwapper.quoteIn(forDesired: buffered, reverse: false)
                if quote.inAmount > 0.0 {
                    let extraCollateral <- self.source.withdrawAvailable(maxAmount: quote.inAmount)
                    if extraCollateral.balance > 0.0 {
                        let extraMOET <- collateralToMoetSwapper.swap(quote: quote, inVault: <-extraCollateral)
                        if extraMOET.balance > 0.0 {
                            self.position.deposit(from: <-extraMOET)
                        } else {
                            Burner.burn(<-extraMOET)
                        }
                    } else {
                        Burner.burn(<-extraCollateral)
                    }
                }
            }

            // Step 7: Create a BufferedSwapSource that converts ALL yield tokens → MOET.
            // Pulling all (not quoteIn-limited) avoids ERC4626 rounding underestimates.
            // After the pre-supplement above, the remaining debt is covered by the yield tokens.
            let moetSource = FlowYieldVaultsStrategiesV2.BufferedSwapSource(
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
            let debtToCollateralSwapper = self._resolveDebtToCollateralSwapper(
                uniqueID: self.uniqueID!,
                collateralConfig: closeCollateralConfig,
                tokens: closeTokens,
                collateralType: collateralType
            )

            var collateralVault <- DeFiActionsUtils.getEmptyVault(collateralType)
            while resultVaults.length > 0 {
                let v <- resultVaults.removeFirst()
                if v.getType() == collateralType {
                    collateralVault.deposit(from: <-v)
                } else if v.balance > 0.0 {
                    if let swapper = debtToCollateralSwapper {
                        // Quote first — if dust is too small to route, destroy it
                        let quote = swapper.quoteOut(forProvided: v.balance, reverse: false)
                        if quote.outAmount > 0.0 {
                            let swapped <- swapper.swap(quote: quote, inVault: <-v)
                            collateralVault.deposit(from: <-swapped)
                        } else {
                            Burner.burn(<-v)
                        }
                    } else {
                        Burner.burn(<-v)
                    }
                } else {
                    Burner.burn(<-v)
                }
            }

            destroy resultVaults
            FlowYieldVaultsStrategiesV2._markPositionClosed(self.uniqueID)
            return <- collateralVault
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
            FlowYieldVaultsStrategiesV2._cleanupPositionClosed(self.uniqueID)
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
        access(self) fun _buildCollateralToDebtSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            let yieldToCollPath = collateralConfig.yieldToCollateralUniV3AddressPath
            let yieldToCollFees = collateralConfig.yieldToCollateralUniV3FeePath
            assert(yieldToCollPath.length >= 2, message: "yieldToCollateral path must have at least 2 elements")
            let collateralEVMAddress = yieldToCollPath[yieldToCollPath.length - 1]
            let underlyingEVMAddress = tokens.underlying4626AssetEVMAddress
            let collateralToUnderlyingFee = yieldToCollFees[yieldToCollFees.length - 1]
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: [collateralEVMAddress, underlyingEVMAddress, tokens.moetTokenEVMAddress],
                feePath: [collateralToUnderlyingFee, UInt32(100)],
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

        /// Resolves the MOET→collateral swapper for closePosition dust handling.
        access(self) fun _resolveDebtToCollateralSwapper(
            uniqueID: DeFiActions.UniqueIdentifier,
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type
        ): {DeFiActions.Swapper}? {
            return self._buildDebtToCollateralSwapper(
                collateralConfig: collateralConfig,
                tokens: tokens,
                collateralType: collateralType,
                uniqueID: uniqueID
            )
        }
    }

    /// This strategy uses syWFLOWv vault (More ERC4626).
    /// Deposits collateral (non-FLOW) into a single FlowALP position, borrowing FLOW as debt.
    /// Borrowed FLOW is deposited directly into the syWFLOWv More ERC4626 vault (no AMM swap needed
    /// since FLOW is the vault's underlying asset).
    /// FLOW (the vault's underlying asset) cannot be used as collateral for this strategy.
    access(all) resource syWFLOWvStrategy : FlowYieldVaults.Strategy, DeFiActions.IdentifiableResource {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let position: @FlowALPv0.Position
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}
        // debtTokenType moved to contract-level config["syWFLOWvDebtTokenTypes"] keyed by uniqueID.id
        /// Kept for Cadence upgrade compatibility — not read by closePosition.
        /// closePosition rebuilds swappers from MoreERC4626CollateralConfig at close time.
        access(self) let yieldToDebtSwapper: {DeFiActions.Swapper}
        /// Kept for Cadence upgrade compatibility — not read by closePosition.
        /// closePosition rebuilds swappers from MoreERC4626CollateralConfig at close time.
        access(self) let debtToCollateralSwapper: {DeFiActions.Swapper}
        /// Tracks whether the underlying FlowALP position has been closed. Once true,
        /// availableBalance() returns 0.0 to avoid panicking when the pool no longer
        /// holds the position (e.g. during YieldVault burnCallback after close).
        access(self) var positionClosed: Bool

        init(
            id: DeFiActions.UniqueIdentifier,
            collateralType: Type,
            position: @FlowALPv0.Position,
            yieldToDebtSwapper: {DeFiActions.Swapper},
            debtToCollateralSwapper: {DeFiActions.Swapper}
        ) {
            self.uniqueID = id
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
            self.yieldToDebtSwapper = yieldToDebtSwapper
            self.debtToCollateralSwapper = debtToCollateralSwapper
            self.positionClosed = false
            self.position <-position
        }

        // Inherited from FlowYieldVaults.Strategy default implementation
        // access(all) view fun isSupportedCollateralType(_ type: Type): Bool

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            // If this strategy was initialized with a stablecoin pre-swap (e.g. PYUSD0→MOET),
            // expose the original (external) collateral type to callers, not the internal MOET type.
            if let id = self.uniqueID {
                if let originalType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(id.id) {
                    return { originalType: true }
                }
            }
            return { self.sink.getSinkType(): true }
        }
        /// Returns the amount available for withdrawal via the inner Source
        access(all) fun availableBalance(ofToken: Type): UFix64 {
            if self.positionClosed { return 0.0 }
            // If stablecoin pre-swap is in effect, match against the original (external) collateral type.
            // MOET and the stablecoin collateral (e.g. PYUSD0) have approximately equal value (1:1).
            var effectiveSourceType = self.source.getSourceType()
            if let id = self.uniqueID {
                if let originalType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(id.id) {
                    effectiveSourceType = originalType
                }
            }
            return ofToken == effectiveSourceType ? self.source.minimumAvailable() : 0.0
        }
        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference.
        /// Accepts both the internal collateral type and, when a pre-swap is configured, the original
        /// external collateral type (e.g. PYUSD0) — which is swapped to MOET first.
        /// FLOW cannot be used as collateral — it is the vault's underlying asset (the debt token).
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                from.getType() == self.sink.getSinkType()
                    || (self.uniqueID != nil && FlowYieldVaultsStrategiesV2._getOriginalCollateralType(self.uniqueID!.id) == from.getType()):
                    "syWFLOWvStrategy position only accepts \(self.sink.getSinkType().identifier) as collateral, got \(from.getType().identifier)"
            }
            // Reject the debt token (FLOW) as collateral — looked up from contract-level config
            if let id = self.uniqueID {
                let debtTokenType = FlowYieldVaultsStrategiesV2._getSyWFLOWvDebtTokenType(id.id)
                assert(
                    debtTokenType == nil || from.getType() != debtTokenType!,
                    message: "syWFLOWvStrategy: FLOW cannot be used as collateral — it is the vault's underlying asset"
                )
            }
            // If depositing the original stablecoin collateral (e.g. PYUSD0), pre-swap to MOET
            if let id = self.uniqueID {
                if from.getType() != self.sink.getSinkType() {
                    if let preSwapper = self._buildCollateralToMoetSwapper(uniqueID: id) {
                        let incoming <- from.withdraw(amount: from.balance)
                        if incoming.balance > 0.0 {
                            let quote = preSwapper.quoteOut(forProvided: incoming.balance, reverse: false)
                            if quote.outAmount > 0.0 {
                                let moetVault <- preSwapper.swap(quote: quote, inVault: <-incoming)
                                self.sink.depositCapacity(from: &moetVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                                Burner.burn(<-moetVault)
                            } else {
                                Burner.burn(<-incoming)
                            }
                        } else {
                            Burner.burn(<-incoming)
                        }
                        return
                    }
                }
            }
            self.sink.depositCapacity(from: from)
        }
        /// Withdraws up to the max amount, returning the withdrawn Vault. If the requested token type is unsupported,
        /// an empty Vault is returned.
        ///
        /// For the PYUSD0 pre-swap case: the internal source type is MOET but the external collateral
        /// type is PYUSD0. We convert MOET→PYUSD0 via the moetToCollateralSwapper.
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            let effectiveSourceType = self.source.getSourceType()
            if ofToken != effectiveSourceType {
                // For pre-swap case: ofToken is external collateral (e.g. PYUSD0), source is MOET.
                if let id = self.uniqueID {
                    if let originalType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(id.id) {
                        if ofToken == originalType {
                            if let moetToOrigSwapper = self._buildMoetToCollateralSwapper(uniqueID: id) {
                                // Quote MOET in to get maxAmount PYUSD0 out
                                let quote = moetToOrigSwapper.quoteIn(forDesired: maxAmount, reverse: false)
                                if quote.inAmount > 0.0 {
                                    let moetVault <- self.source.withdrawAvailable(maxAmount: quote.inAmount)
                                    if moetVault.balance > 0.0 {
                                        return <- moetToOrigSwapper.swap(quote: nil, inVault: <-moetVault)
                                    }
                                    Burner.burn(<-moetVault)
                                }
                            }
                        }
                    }
                }
                return <- DeFiActionsUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }
        /// Closes the underlying FlowALP position by preparing FLOW repayment funds from AutoBalancer
        /// (via the stored yield→FLOW swapper) and closing with them. When a stablecoin pre-swap is
        /// configured (e.g. PYUSD0→MOET), the returned MOET collateral is swapped back to the
        /// original stablecoin before returning.
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            post {
                result.getType() == collateralType: "Withdraw Vault (\(result.getType().identifier)) is not of a requested collateral type (\(collateralType.identifier))"
            }

            // Determine the internal collateral type (may be MOET if a pre-swap was applied)
            var internalCollateralType = collateralType
            if let id = self.uniqueID {
                if FlowYieldVaultsStrategiesV2._getOriginalCollateralType(id.id) != nil {
                    internalCollateralType = self.sink.getSinkType()  // MOET
                }
            }

            // Step 1: Get debt amounts
            let debtsByType = self.position.getTotalDebt()

            assert(
                debtsByType.length <= 1,
                message: "syWFLOWvStrategy position must have at most one debt type, found \(debtsByType.length)"
            )

            var totalDebtAmount: UFix64 = 0.0
            for debtAmount in debtsByType.values {
                totalDebtAmount = totalDebtAmount + debtAmount
            }

            // Step 2: If no debt, close with empty sources array
            if totalDebtAmount == 0.0 {
                let resultVaults <- self.position.closePosition(repaymentSources: [])
                assert(
                    resultVaults.length <= 1,
                    message: "Expected 0 or 1 collateral vault from closePosition, got \(resultVaults.length)"
                )
                if resultVaults.length == 0 {
                    destroy resultVaults
                    self.positionClosed = true
                    return <- DeFiActionsUtils.getEmptyVault(collateralType)
                }
                var collateralVault <- resultVaults.removeFirst()
                destroy resultVaults
                // Convert internal collateral (MOET) → external collateral (e.g. PYUSD0) if needed
                if internalCollateralType != collateralType {
                    if let id = self.uniqueID {
                        if let moetToOrigSwapper = self._buildMoetToCollateralSwapper(uniqueID: id) {
                            if collateralVault.balance > 0.0 {
                                let quote = moetToOrigSwapper.quoteOut(forProvided: collateralVault.balance, reverse: false)
                                if quote.outAmount > 0.0 {
                                    let extVault <- moetToOrigSwapper.swap(quote: quote, inVault: <-collateralVault)
                                    self.positionClosed = true
                                    return <- extVault
                                }
                            }
                            Burner.burn(<-collateralVault)
                            self.positionClosed = true
                            return <- DeFiActionsUtils.getEmptyVault(collateralType)
                        }
                    }
                    Burner.burn(<-collateralVault)
                    self.positionClosed = true
                    return <- DeFiActionsUtils.getEmptyVault(collateralType)
                }
                self.positionClosed = true
                return <- collateralVault
            }

            // Step 3: Reconstruct MoreERC4626CollateralConfig and swappers from contract-level config.
            // The swappers are not read from the stored resource fields (yieldToDebtSwapper /
            // debtToCollateralSwapper); instead they are rebuilt at close time from the shared
            // per-strategy config — the same pattern used by FUSDEVStrategy.closePosition.
            //
            // For the stablecoin path (e.g. PYUSD0 → MOET pre-swap), _getOriginalCollateralType
            // gives the user-facing key for the MoreERC4626CollateralConfig lookup.
            let closeCollateralKey = self.uniqueID != nil
                ? FlowYieldVaultsStrategiesV2._getOriginalCollateralType(self.uniqueID!.id) ?? collateralType
                : collateralType
            let closeConfig = self._getStoredMoreERC4626Config(
                strategyType: Type<@syWFLOWvStrategy>(),
                collateralType: closeCollateralKey
            ) ?? panic("No MoreERC4626CollateralConfig for syWFLOWvStrategy with \(closeCollateralKey.identifier)")
            let closeTokens = FlowYieldVaultsStrategiesV2._resolveTokenBundle(
                yieldTokenEVMAddress: closeConfig.yieldTokenEVMAddress
            )
            let syWFLOWvToFlow = self._buildSyWFLOWvToFlowSwapper(
                closeConfig: closeConfig,
                closeTokens: closeTokens,
                uniqueID: self.uniqueID!
            )
            let flowToCollateral = self._buildFlowToCollateralSwapper(
                closeConfig: closeConfig,
                closeTokens: closeTokens,
                internalCollateralType: internalCollateralType,
                uniqueID: self.uniqueID!
            )

            // Step 4: Create external syWFLOWv source from AutoBalancer
            let yieldTokenSource = FlowYieldVaultsAutoBalancers.createExternalSource(id: self.id()!)
                ?? panic("Could not create external source from AutoBalancer")

            // Step 5: Create a BufferedSwapSource that converts ALL syWFLOWv → FLOW for debt repayment.
            // Pulls all available tokens (not quoteIn-limited) to avoid ERC4626 rounding underestimates
            // that would leave us short of the required FLOW debt. Any FLOW overpayment is returned as
            // dust and converted back to collateral below.
            let flowSource = BufferedSwapSource(
                swapper: syWFLOWvToFlow,
                source: yieldTokenSource,
                uniqueID: self.copyID()
            )

            // Step 6: Pre-supplement from collateral if yield tokens are insufficient to cover the FLOW debt.
            //
            // The syWFLOWv close path has a structural round-trip fee loss:
            //   Open:  FLOW → syWFLOWv (ERC4626 deposit, free)
            //   Close: syWFLOWv → FLOW (UniV3 AMM swap, ~0.3% fee)
            // In production, accrued yield more than covers this; with no accrued yield (e.g. in
            // tests, immediate open+close), the yield tokens convert back to slightly less FLOW
            // than was borrowed. We handle this by pre-pulling a tiny amount of collateral from
            // self.source, swapping it to FLOW via flowToCollateral in reverse, and depositing it
            // into the position to reduce the outstanding debt — BEFORE calling position.closePosition.
            //
            // This MUST be done before closePosition because the position is locked during close:
            // any attempt to pull from self.source inside a repaymentSource.withdrawAvailable call
            // would trigger "Reentrancy: position X is locked".
            let expectedFlow = flowSource.minimumAvailable()
            if expectedFlow < totalDebtAmount {
                let shortfall = totalDebtAmount - expectedFlow
                // Add 1% buffer to account for swap slippage/rounding in the collateral→FLOW leg
                let buffered = shortfall + shortfall / 100.0
                let quote = flowToCollateral.quoteIn(forDesired: buffered, reverse: true)
                if quote.inAmount > 0.0 {
                    let extraCollateral <- self.source.withdrawAvailable(maxAmount: quote.inAmount)
                    if extraCollateral.balance > 0.0 {
                        let extraFlow <- flowToCollateral.swapBack(quote: quote, residual: <-extraCollateral)
                        if extraFlow.balance > 0.0 {
                            self.position.deposit(from: <-extraFlow)
                        } else {
                            Burner.burn(<-extraFlow)
                        }
                    } else {
                        Burner.burn(<-extraCollateral)
                    }
                }
            }

            // Step 7: Close position — pool pulls the (now pre-reduced) FLOW debt from flowSource
            let resultVaults <- self.position.closePosition(repaymentSources: [flowSource])

            // closePosition returns vaults in dict-iteration order (hash-based), so we cannot
            // assume the collateral vault is first. Iterate all vaults: collect collateral by type
            // and convert any non-collateral vaults (FLOW overpayment dust) back to collateral.
            var collateralVault <- DeFiActionsUtils.getEmptyVault(internalCollateralType)
            while resultVaults.length > 0 {
                let v <- resultVaults.removeFirst()
                if v.getType() == internalCollateralType {
                    collateralVault.deposit(from: <-v)
                } else if v.balance > 0.0 {
                    // FLOW overpayment dust — convert back to collateral if routable
                    let quote = flowToCollateral.quoteOut(forProvided: v.balance, reverse: false)
                    if quote.outAmount > 0.0 {
                        let swapped <- flowToCollateral.swap(quote: quote, inVault: <-v)
                        collateralVault.deposit(from: <-swapped)
                    } else {
                        Burner.burn(<-v)
                    }
                } else {
                    Burner.burn(<-v)
                }
            }

            destroy resultVaults

            // Convert internal collateral (MOET) → external collateral (e.g. PYUSD0) if needed
            if internalCollateralType != collateralType {
                if let id = self.uniqueID {
                    if let moetToOrigSwapper = self._buildMoetToCollateralSwapper(uniqueID: id) {
                        if collateralVault.balance > 0.0 {
                            let quote = moetToOrigSwapper.quoteOut(forProvided: collateralVault.balance, reverse: false)
                            if quote.outAmount > 0.0 {
                                let extVault <- moetToOrigSwapper.swap(quote: quote, inVault: <-collateralVault)
                                self.positionClosed = true
                                return <- extVault
                            }
                        }
                    }
                }
                Burner.burn(<-collateralVault)
                self.positionClosed = true
                return <- DeFiActionsUtils.getEmptyVault(collateralType)
            }

            self.positionClosed = true
            return <- collateralVault
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer and contract-level config entries
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancers._cleanupAutoBalancer(id: self.id()!)
            FlowYieldVaultsStrategiesV2._removeSyWFLOWvDebtTokenType(self.uniqueID?.id)
            // Clean up stablecoin pre-swap config entries (no-op if not set)
            if let id = self.uniqueID {
                FlowYieldVaultsStrategiesV2._removeOriginalCollateralType(id.id)
            }
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

        access(self) fun _getStoredMoreERC4626Config(
            strategyType: Type,
            collateralType: Type
        ): MoreERC4626CollateralConfig? {
            return FlowYieldVaultsStrategiesV2._getMoreERC4626Config(
                composer: Type<@MoreERC4626StrategyComposer>(),
                strategy: strategyType,
                collateral: collateralType
            )
        }

        /// Builds a syWFLOWv→FLOW UniV3 swapper from MoreERC4626CollateralConfig.
        access(self) fun _buildSyWFLOWvToFlowSwapper(
            closeConfig: FlowYieldVaultsStrategiesV2.MoreERC4626CollateralConfig,
            closeTokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: closeConfig.yieldToUnderlyingUniV3AddressPath,
                feePath: closeConfig.yieldToUnderlyingUniV3FeePath,
                inVault: closeTokens.yieldTokenType,
                outVault: closeTokens.underlying4626AssetType,  // FlowToken.Vault
                uniqueID: uniqueID
            )
        }

        /// Builds a collateral→MOET UniV3 swapper from MoetPreswapConfig for the deposit pre-swap.
        /// Returns nil if no preswap is configured for this position (non-stablecoin collateral).
        access(self) fun _buildCollateralToMoetSwapper(
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper? {
            if let origType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(uniqueID.id) {
                if let preswapCfg = FlowYieldVaultsStrategiesV2._getMoetPreswapConfig(
                    composer: Type<@MoreERC4626StrategyComposer>(),
                    collateral: origType
                ) {
                    let moetType = FlowYieldVaultsStrategiesV2._getPoolDefaultToken()
                    return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                        tokenPath: preswapCfg.collateralToMoetAddressPath,
                        feePath: preswapCfg.collateralToMoetFeePath,
                        inVault: origType,
                        outVault: moetType,
                        uniqueID: uniqueID
                    )
                }
            }
            return nil
        }

        /// Builds a MOET→originalCollateral UniV3 swapper from MoetPreswapConfig (reversed path).
        /// Returns nil if no preswap is configured for this position (non-stablecoin collateral).
        access(self) fun _buildMoetToCollateralSwapper(
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper? {
            if let origType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(uniqueID.id) {
                if let preswapCfg = FlowYieldVaultsStrategiesV2._getMoetPreswapConfig(
                    composer: Type<@MoreERC4626StrategyComposer>(),
                    collateral: origType
                ) {
                    let moetType = FlowYieldVaultsStrategiesV2._getPoolDefaultToken()
                    return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                        tokenPath: preswapCfg.collateralToMoetAddressPath.reverse(),
                        feePath: preswapCfg.collateralToMoetFeePath.reverse(),
                        inVault: moetType,
                        outVault: origType,
                        uniqueID: uniqueID
                    )
                }
            }
            return nil
        }

        /// Builds a FLOW→internalCollateral UniV3 swapper from MoreERC4626CollateralConfig.
        /// Handles both the standard path (FLOW→WBTC/WETH) and the stablecoin path (FLOW→PYUSD0→MOET).
        access(self) fun _buildFlowToCollateralSwapper(
            closeConfig: FlowYieldVaultsStrategiesV2.MoreERC4626CollateralConfig,
            closeTokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            internalCollateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            // Stablecoin path (e.g. PYUSD0→MOET pre-swap): extend the FLOW→PYUSD0 path with a PYUSD0→MOET hop.
            if let origType = FlowYieldVaultsStrategiesV2._getOriginalCollateralType(uniqueID.id) {
                if let preswapCfg = FlowYieldVaultsStrategiesV2._getMoetPreswapConfig(
                    composer: Type<@MoreERC4626StrategyComposer>(),
                    collateral: origType
                ) {
                    var path = closeConfig.debtToCollateralUniV3AddressPath
                    path.append(preswapCfg.collateralToMoetAddressPath[preswapCfg.collateralToMoetAddressPath.length - 1])
                    var fees = closeConfig.debtToCollateralUniV3FeePath
                    fees.append(preswapCfg.collateralToMoetFeePath[preswapCfg.collateralToMoetFeePath.length - 1])
                    return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                        tokenPath: path,
                        feePath: fees,
                        inVault: closeTokens.underlying4626AssetType,  // FLOW
                        outVault: internalCollateralType,               // MOET
                        uniqueID: uniqueID
                    )
                }
            }
            // Standard path (WBTC/WETH): FLOW → collateral directly.
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: closeConfig.debtToCollateralUniV3AddressPath,
                feePath: closeConfig.debtToCollateralUniV3FeePath,
                inVault: closeTokens.underlying4626AssetType,  // FLOW
                outVault: internalCollateralType,
                uniqueID: uniqueID
            )
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
        recurringConfig: DeFiActions.AutoBalancerRecurringConfig?,
        uniqueID: DeFiActions.UniqueIdentifier
    ): FlowYieldVaultsStrategiesV2.AutoBalancerIO {
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

        return FlowYieldVaultsStrategiesV2.AutoBalancerIO(
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
            assert(yieldToCollPath.length >= 2, message: "yieldToCollateral path must have at least 2 elements")
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

    /// This StrategyComposer builds strategies that borrow the ERC4626 vault's own underlying
    /// asset as debt (e.g. FLOW for syWFLOWv), depositing it directly via ERC4626 deposit/redeem
    /// with no AMM swaps. FLOW (the underlying) cannot be used as collateral.
    access(all) resource MoreERC4626StrategyComposer : FlowYieldVaults.StrategyComposer {
        /// { Strategy Type: { Collateral Type: MoreERC4626CollateralConfig } }
        access(self) let config: {Type: {Type: MoreERC4626CollateralConfig}}

        init(_ config: {Type: {Type: MoreERC4626CollateralConfig}}) {
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

        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return self._supportsCollateral(forStrategy: forStrategy, collateral: initializedWith)
                ? { initializedWith: true }
                : {}
        }

        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{FlowYieldVaults.Strategy} {
            pre {
                self.config[type] != nil: "Unsupported strategy type \(type.identifier)"
            }

            switch type {
            case Type<@syWFLOWvStrategy>():
                let collateralType = withFunds.getType()

                let stratConfig = self.config[Type<@syWFLOWvStrategy>()]
                    ?? panic("Could not find config for strategy syWFLOWvStrategy")
                let collateralConfig = stratConfig[collateralType]
                    ?? panic("Could not find config for collateral \(collateralType.identifier) when creating syWFLOWvStrategy")

                let tokens = FlowYieldVaultsStrategiesV2._resolveTokenBundle(
                    yieldTokenEVMAddress: collateralConfig.yieldTokenEVMAddress
                )

                // Reject FLOW as collateral — it is the vault's underlying / debt token
                assert(
                    collateralType != tokens.underlying4626AssetType,
                    message: "syWFLOWvStrategy: FLOW cannot be used as collateral — it is the vault's underlying asset"
                )

                let yieldTokenOracle = FlowYieldVaultsStrategiesV2._createYieldTokenOracle(
                    yieldTokenEVMAddress: tokens.yieldTokenEVMAddress,
                    underlyingAssetType: tokens.underlying4626AssetType,
                    uniqueID: uniqueID
                )

                let recurringConfig = FlowYieldVaultsStrategiesV2._createRecurringConfig(withID: uniqueID)

                let balancerIO = FlowYieldVaultsStrategiesV2._initAutoBalancerAndIO(
                    oracle: yieldTokenOracle,
                    yieldTokenType: tokens.yieldTokenType,
                    recurringConfig: recurringConfig,
                    uniqueID: uniqueID
                )

                // For syWFLOWvStrategy the debt token IS the underlying asset (FLOW), not MOET.
                let flowDebtTokenType = tokens.underlying4626AssetType

                // FLOW → syWFLOWv: standard ERC4626 deposit (More vault, not Morpho — no AMM needed)
                let flowToSyWFLOWv = ERC4626SwapConnectors.Swapper(
                    asset: tokens.underlying4626AssetType,
                    vault: tokens.yieldTokenEVMAddress,
                    coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                    feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                    uniqueID: uniqueID
                )
                // syWFLOWv → FLOW: UniV3 AMM swap (More vault does not support synchronous ERC4626 redeem)
                let syWFLOWvToFlow = UniswapV3SwapConnectors.Swapper(
                    factoryAddress: FlowYieldVaultsStrategiesV2.univ3FactoryEVMAddress,
                    routerAddress: FlowYieldVaultsStrategiesV2.univ3RouterEVMAddress,
                    quoterAddress: FlowYieldVaultsStrategiesV2.univ3QuoterEVMAddress,
                    tokenPath: collateralConfig.yieldToUnderlyingUniV3AddressPath,
                    feePath: collateralConfig.yieldToUnderlyingUniV3FeePath,
                    inVault: tokens.yieldTokenType,
                    outVault: tokens.underlying4626AssetType,
                    coaCapability: FlowYieldVaultsStrategiesV2._getCOACapability(),
                    uniqueID: uniqueID
                )

                // issuanceSink: pool pushes borrowed FLOW → deposit → syWFLOWv → AutoBalancer
                let abaSwapSinkFlow = SwapConnectors.SwapSink(
                    swapper: flowToSyWFLOWv,
                    sink: balancerIO.sink,
                    uniqueID: uniqueID
                )
                // repaymentSource: AutoBalancer → syWFLOWv → AMM swap → FLOW → pool
                let abaSwapSourceFlow = SwapConnectors.SwapSource(
                    swapper: syWFLOWvToFlow,
                    source: balancerIO.source,
                    uniqueID: uniqueID
                )

                // --- Stablecoin pre-swap path (e.g. PYUSD0 → MOET) ---
                if let preswapCfg = FlowYieldVaultsStrategiesV2._getMoetPreswapConfig(
                    composer: Type<@MoreERC4626StrategyComposer>(),
                    collateral: collateralType
                ) {
                    let preSwapper = UniswapV3SwapConnectors.Swapper(
                        factoryAddress: FlowYieldVaultsStrategiesV2.univ3FactoryEVMAddress,
                        routerAddress: FlowYieldVaultsStrategiesV2.univ3RouterEVMAddress,
                        quoterAddress: FlowYieldVaultsStrategiesV2.univ3QuoterEVMAddress,
                        tokenPath: preswapCfg.collateralToMoetAddressPath,
                        feePath: preswapCfg.collateralToMoetFeePath,
                        inVault: collateralType,
                        outVault: tokens.moetTokenType,
                        coaCapability: FlowYieldVaultsStrategiesV2._getCOACapability(),
                        uniqueID: uniqueID
                    )
                    let preSwapQuote = preSwapper.quoteOut(forProvided: withFunds.balance, reverse: false)
                    let moetFunds <- preSwapper.swap(quote: preSwapQuote, inVault: <-withFunds)

                    // Open FlowALP position with MOET as collateral
                    let positionPreswap <- FlowYieldVaultsStrategiesV2._openCreditPosition(
                        funds: <-moetFunds,
                        issuanceSink: abaSwapSinkFlow,
                        repaymentSource: abaSwapSourceFlow
                    )

                    // AutoBalancer debt management: same as WBTC/WETH (manages FLOW borrow/repay)
                    let positionDebtSinkPre = positionPreswap.createSinkWithOptions(
                        type: flowDebtTokenType,
                        pushToDrawDownSink: false
                    )
                    let positionDebtSwapSinkPre = SwapConnectors.SwapSink(
                        swapper: syWFLOWvToFlow,
                        sink: positionDebtSinkPre,
                        uniqueID: uniqueID
                    )
                    let positionDebtSourcePre = positionPreswap.createSourceWithOptions(
                        type: flowDebtTokenType,
                        pullFromTopUpSource: false
                    )
                    let positionDebtSwapSourcePre = SwapConnectors.SwapSource(
                        swapper: flowToSyWFLOWv,
                        source: positionDebtSourcePre,
                        uniqueID: uniqueID
                    )
                    balancerIO.autoBalancer.setSink(positionDebtSwapSinkPre, updateSinkID: true)
                    balancerIO.autoBalancer.setSource(positionDebtSwapSourcePre, updateSourceID: true)

                    FlowYieldVaultsStrategiesV2._setSyWFLOWvDebtTokenType(uniqueID.id, flowDebtTokenType)
                    FlowYieldVaultsStrategiesV2._setOriginalCollateralType(uniqueID.id, collateralType)

                    return <-create syWFLOWvStrategy(
                        id: uniqueID,
                        collateralType: tokens.moetTokenType,
                        position: <-positionPreswap,
                        yieldToDebtSwapper: syWFLOWvToFlow,
                        debtToCollateralSwapper: syWFLOWvToFlow  // field unused at close time; rebuilt from config
                    )
                }

                // --- Standard path (WBTC, WETH — directly supported by FlowALP) ---

                // Open FlowALP position with collateral; drawDownSink accepts FLOW
                let positionFlow <- FlowYieldVaultsStrategiesV2._openCreditPosition(
                    funds: <-withFunds,
                    issuanceSink: abaSwapSinkFlow,
                    repaymentSource: abaSwapSourceFlow
                )

                // AutoBalancer overflow: excess syWFLOWv → AMM swap → FLOW → repay position debt
                let positionDebtSink = positionFlow.createSinkWithOptions(
                    type: flowDebtTokenType,
                    pushToDrawDownSink: false
                )
                let positionDebtSwapSink = SwapConnectors.SwapSink(
                    swapper: syWFLOWvToFlow,
                    sink: positionDebtSink,
                    uniqueID: uniqueID
                )

                // AutoBalancer deficit: borrow more FLOW from position → deposit → syWFLOWv
                let positionDebtSource = positionFlow.createSourceWithOptions(
                    type: flowDebtTokenType,
                    pullFromTopUpSource: false
                )
                let positionDebtSwapSource = SwapConnectors.SwapSource(
                    swapper: flowToSyWFLOWv,
                    source: positionDebtSource,
                    uniqueID: uniqueID
                )

                balancerIO.autoBalancer.setSink(positionDebtSwapSink, updateSinkID: true)
                balancerIO.autoBalancer.setSource(positionDebtSwapSource, updateSourceID: true)

                // Store debtTokenType in contract-level config (resource field removed for upgrade compat)
                FlowYieldVaultsStrategiesV2._setSyWFLOWvDebtTokenType(uniqueID.id, flowDebtTokenType)

                return <-create syWFLOWvStrategy(
                    id: uniqueID,
                    collateralType: collateralType,
                    position: <-positionFlow,
                    yieldToDebtSwapper: syWFLOWvToFlow,
                    debtToCollateralSwapper: syWFLOWvToFlow  // field unused at close time; rebuilt from config
                )

            default:
                panic("Unsupported strategy type \(type.identifier)")
            }
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

    access(self)
    fun makeMoreERC4626CollateralConfig(
        yieldTokenEVMAddress: EVM.EVMAddress,
        yieldToUnderlyingAddressPath: [EVM.EVMAddress],
        yieldToUnderlyingFeePath: [UInt32],
        debtToCollateralAddressPath: [EVM.EVMAddress],
        debtToCollateralFeePath: [UInt32]
    ): MoreERC4626CollateralConfig {
        pre {
            yieldToUnderlyingAddressPath.length > 1:
                "Invalid Uniswap V3 swap path length"
            yieldToUnderlyingFeePath.length == yieldToUnderlyingAddressPath.length - 1:
                "Uniswap V3 fee path length must be path length - 1"
            yieldToUnderlyingAddressPath[0].equals(yieldTokenEVMAddress):
                "UniswapV3 swap path must start with yield token"
            debtToCollateralAddressPath.length > 1:
                "Invalid debt-to-collateral Uniswap V3 path length"
            debtToCollateralFeePath.length == debtToCollateralAddressPath.length - 1:
                "Debt-to-collateral Uniswap V3 fee path length must be path length - 1"
        }
        return MoreERC4626CollateralConfig(
            yieldTokenEVMAddress: yieldTokenEVMAddress,
            yieldToUnderlyingUniV3AddressPath: yieldToUnderlyingAddressPath,
            yieldToUnderlyingUniV3FeePath: yieldToUnderlyingFeePath,
            debtToCollateralUniV3AddressPath: debtToCollateralAddressPath,
            debtToCollateralUniV3FeePath: debtToCollateralFeePath
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
            return FlowYieldVaultsStrategiesV2._getMoreERC4626Config(
                composer: composer, strategy: strategy, collateral: collateral
            ) != nil
        }

        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return {
                Type<@MorphoERC4626StrategyComposer>(): true,
                Type<@MoreERC4626StrategyComposer>(): true
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
                || type == Type<@MoreERC4626StrategyComposer>()
        }

        access(all) fun issueComposer(_ type: Type): @{FlowYieldVaults.StrategyComposer} {
            pre {
                self.isSupportedComposer(type): "Unsupported StrategyComposer \(type.identifier) requested"
            }
            switch type {
            case Type<@MorphoERC4626StrategyComposer>():
                return <- create MorphoERC4626StrategyComposer(self.configs[type] ?? {})
            case Type<@MoreERC4626StrategyComposer>():
                return <- create MoreERC4626StrategyComposer(
                    FlowYieldVaultsStrategiesV2._getMoreERC4626ComposerConfig(type)
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

        /// Merges new MoreERC4626CollateralConfig entries into the MoreERC4626StrategyComposer config.
        access(Configure)
        fun upsertMoreERC4626Config(
            config: {Type: {Type: FlowYieldVaultsStrategiesV2.MoreERC4626CollateralConfig}}
        ) {
            for stratType in config.keys {
                assert(stratType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()),
                    message: "Invalid config key \(stratType.identifier) - not a FlowYieldVaults.Strategy Type")
                for collateralType in config[stratType]!.keys {
                    assert(collateralType.isSubtype(of: Type<@{FungibleToken.Vault}>()),
                        message: "Invalid config key at config[\(stratType.identifier)] - \(collateralType.identifier) is not a FungibleToken.Vault")
                }
            }

            let composerType = Type<@MoreERC4626StrategyComposer>()
            for stratType in config.keys {
                let newPerCollateral = config[stratType]!
                for collateralType in newPerCollateral.keys {
                    FlowYieldVaultsStrategiesV2._setMoreERC4626Config(
                        composer: composerType,
                        strategy: stratType,
                        collateral: collateralType,
                        cfg: newPerCollateral[collateralType]!
                    )
                }
            }
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

        access(Configure) fun addOrUpdateMoreERC4626CollateralConfig(
            strategyType: Type,
            collateralVaultType: Type,
            yieldTokenEVMAddress: EVM.EVMAddress,
            yieldToUnderlyingAddressPath: [EVM.EVMAddress],
            yieldToUnderlyingFeePath: [UInt32],
            debtToCollateralAddressPath: [EVM.EVMAddress],
            debtToCollateralFeePath: [UInt32]
        ) {
            pre {
                strategyType.isSubtype(of: Type<@{FlowYieldVaults.Strategy}>()):
                    "Strategy type \(strategyType.identifier) is not a FlowYieldVaults.Strategy"
                collateralVaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                    "Collateral type \(collateralVaultType.identifier) is not a FungibleToken.Vault"
            }

            let cfg = FlowYieldVaultsStrategiesV2.makeMoreERC4626CollateralConfig(
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                yieldToUnderlyingAddressPath: yieldToUnderlyingAddressPath,
                yieldToUnderlyingFeePath: yieldToUnderlyingFeePath,
                debtToCollateralAddressPath: debtToCollateralAddressPath,
                debtToCollateralFeePath: debtToCollateralFeePath
            )
            self.upsertMoreERC4626Config(config: { strategyType: { collateralVaultType: cfg } })
        }

        /// Configures a stablecoin collateral type to use MOET pre-swap before depositing into
        /// FlowALP. Required for stablecoins like PYUSD0 that FlowALP does not support directly
        /// as collateral (it only accepts MOET as its stablecoin).
        ///
        /// collateralToMoetAddressPath: full UniV3 path from collateral EVM address → MOET EVM address
        /// collateralToMoetFeePath:     UniV3 fee tiers for each hop (length = path length - 1)
        access(Configure) fun upsertMoetPreswapConfig(
            composer: Type,
            collateralVaultType: Type,
            collateralToMoetAddressPath: [EVM.EVMAddress],
            collateralToMoetFeePath: [UInt32]
        ) {
            pre {
                composer == Type<@MorphoERC4626StrategyComposer>()
                    || composer == Type<@MoreERC4626StrategyComposer>():
                    "composer must be MorphoERC4626StrategyComposer or MoreERC4626StrategyComposer"
                collateralVaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                    "collateralVaultType must be a FungibleToken.Vault"
                collateralToMoetAddressPath.length > 1:
                    "Path must have at least 2 elements"
                collateralToMoetFeePath.length == collateralToMoetAddressPath.length - 1:
                    "Fee path length must equal address path length - 1"
            }
            FlowYieldVaultsStrategiesV2._setMoetPreswapConfig(
                composer: composer,
                collateral: collateralVaultType,
                cfg: FlowYieldVaultsStrategiesV2.MoetPreswapConfig(
                    collateralToMoetAddressPath: collateralToMoetAddressPath,
                    collateralToMoetFeePath: collateralToMoetFeePath
                )
            )
        }

        access(Configure) fun purgeConfig() {
            self.configs = {
                Type<@MorphoERC4626StrategyComposer>(): {
                    Type<@FUSDEVStrategy>(): {} as {Type: CollateralConfig}
                }
            }
            FlowYieldVaultsStrategiesV2._purgeMoreERC4626Configs()
            FlowYieldVaultsStrategiesV2.config["moetPreswapConfigs"] = {} as {Type: {Type: FlowYieldVaultsStrategiesV2.MoetPreswapConfig}}
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

    // --- "closedPositions" partition ---

    access(contract) view fun _isPositionClosed(_ uniqueID: DeFiActions.UniqueIdentifier?): Bool {
        if uniqueID == nil { return false }
        let partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
        return partition[uniqueID!.id] ?? false
    }

    access(contract) fun _markPositionClosed(_ uniqueID: DeFiActions.UniqueIdentifier?) {
        if let id = uniqueID {
            var partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
            partition[id.id] = true
            FlowYieldVaultsStrategiesV2.config["closedPositions"] = partition
        }
    }

    access(contract) fun _cleanupPositionClosed(_ uniqueID: DeFiActions.UniqueIdentifier?) {
        if let id = uniqueID {
            var partition = FlowYieldVaultsStrategiesV2.config["closedPositions"] as! {UInt64: Bool}? ?? {}
            partition.remove(key: id.id)
            FlowYieldVaultsStrategiesV2.config["closedPositions"] = partition
        }
    }

    // --- "syWFLOWvDebtTokenTypes" partition ---
    // Stores the debt token Type per syWFLOWvStrategy uniqueID.
    // Kept in the contract-level config map so no new field is added to the deployed syWFLOWvStrategy resource.

    access(contract) view fun _getSyWFLOWvDebtTokenType(_ id: UInt64): Type? {
        let partition = FlowYieldVaultsStrategiesV2.config["syWFLOWvDebtTokenTypes"] as! {UInt64: Type}? ?? {}
        return partition[id]
    }

    access(contract) fun _setSyWFLOWvDebtTokenType(_ id: UInt64, _ t: Type) {
        var partition = FlowYieldVaultsStrategiesV2.config["syWFLOWvDebtTokenTypes"] as! {UInt64: Type}? ?? {}
        partition[id] = t
        FlowYieldVaultsStrategiesV2.config["syWFLOWvDebtTokenTypes"] = partition
    }

    access(contract) fun _removeSyWFLOWvDebtTokenType(_ id: UInt64?) {
        if let unwrappedID = id {
            var partition = FlowYieldVaultsStrategiesV2.config["syWFLOWvDebtTokenTypes"] as! {UInt64: Type}? ?? {}
            partition.remove(key: unwrappedID)
            FlowYieldVaultsStrategiesV2.config["syWFLOWvDebtTokenTypes"] = partition
        }
    }

    // --- "moreERC4626Configs" partition ---
    // Stores MoreERC4626CollateralConfig keyed by composer type → strategy type → collateral type.
    // Kept in the contract-level config map so no new field is added to the deployed StrategyComposerIssuer resource.

    access(contract) view fun _getMoreERC4626Config(
        composer: Type,
        strategy: Type,
        collateral: Type
    ): MoreERC4626CollateralConfig? {
        let partition = FlowYieldVaultsStrategiesV2.config["moreERC4626Configs"]
            as! {Type: {Type: {Type: MoreERC4626CollateralConfig}}}? ?? {}
        if let composerPart = partition[composer] {
            if let stratPart = composerPart[strategy] {
                return stratPart[collateral]
            }
        }
        return nil
    }

    access(contract) view fun _getMoreERC4626ComposerConfig(
        _ composerType: Type
    ): {Type: {Type: MoreERC4626CollateralConfig}} {
        let partition = FlowYieldVaultsStrategiesV2.config["moreERC4626Configs"]
            as! {Type: {Type: {Type: MoreERC4626CollateralConfig}}}? ?? {}
        return partition[composerType] ?? {}
    }

    access(contract) fun _setMoreERC4626Config(
        composer: Type,
        strategy: Type,
        collateral: Type,
        cfg: MoreERC4626CollateralConfig
    ) {
        var partition = FlowYieldVaultsStrategiesV2.config["moreERC4626Configs"]
            as! {Type: {Type: {Type: MoreERC4626CollateralConfig}}}? ?? {}
        var composerPartition = partition[composer] ?? {}
        var stratPartition = composerPartition[strategy] ?? {}
        stratPartition[collateral] = cfg
        composerPartition[strategy] = stratPartition
        partition[composer] = composerPartition
        FlowYieldVaultsStrategiesV2.config["moreERC4626Configs"] = partition
    }

    access(contract) fun _purgeMoreERC4626Configs() {
        FlowYieldVaultsStrategiesV2.config["moreERC4626Configs"] = {} as {Type: {Type: {Type: MoreERC4626CollateralConfig}}}
    }

    // --- "originalCollateralTypes" partition ---
    // Stores the original (external) collateral type per strategy uniqueID when a MOET pre-swap
    // is in effect. E.g. PYUSD0 when the position internally holds MOET.

    access(contract) view fun _getOriginalCollateralType(_ id: UInt64): Type? {
        let partition = FlowYieldVaultsStrategiesV2.config["originalCollateralTypes"] as! {UInt64: Type}? ?? {}
        return partition[id]
    }

    access(contract) fun _setOriginalCollateralType(_ id: UInt64, _ t: Type) {
        var partition = FlowYieldVaultsStrategiesV2.config["originalCollateralTypes"] as! {UInt64: Type}? ?? {}
        partition[id] = t
        FlowYieldVaultsStrategiesV2.config["originalCollateralTypes"] = partition
    }

    access(contract) fun _removeOriginalCollateralType(_ id: UInt64) {
        var partition = FlowYieldVaultsStrategiesV2.config["originalCollateralTypes"] as! {UInt64: Type}? ?? {}
        partition.remove(key: id)
        FlowYieldVaultsStrategiesV2.config["originalCollateralTypes"] = partition
    }

    // --- "moetPreswapConfigs" partition ---
    // Static admin config: keyed by composerType → collateralType → MoetPreswapConfig.
    // Checked during createStrategy to determine whether a collateral needs MOET pre-swap.

    access(contract) view fun _getMoetPreswapConfig(
        composer: Type,
        collateral: Type
    ): MoetPreswapConfig? {
        let partition = FlowYieldVaultsStrategiesV2.config["moetPreswapConfigs"]
            as! {Type: {Type: MoetPreswapConfig}}? ?? {}
        let p = partition[composer] ?? {}
        return p[collateral]
    }

    access(contract) fun _setMoetPreswapConfig(
        composer: Type,
        collateral: Type,
        cfg: MoetPreswapConfig
    ) {
        var partition = FlowYieldVaultsStrategiesV2.config["moetPreswapConfigs"]
            as! {Type: {Type: MoetPreswapConfig}}? ?? {}
        var p = partition[composer] ?? {}
        p[collateral] = cfg
        partition[composer] = p
        FlowYieldVaultsStrategiesV2.config["moetPreswapConfigs"] = partition
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
