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
    ///   "moreERC4626Configs"         → {Type: {Type: {Type: MoreERC4626CollateralConfig}}}
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

    /// @deprecated — no longer used. Retained for Cadence upgrade compatibility (structs cannot
    /// be removed once deployed on-chain).
    access(all) struct MoetPreswapConfig {
        access(all) let collateralToMoetAddressPath: [EVM.EVMAddress]
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
            pre {
                yieldToUnderlyingUniV3AddressPath.length > 1:
                    "Invalid yieldToUnderlying UniV3 path length"
                yieldToUnderlyingUniV3FeePath.length == yieldToUnderlyingUniV3AddressPath.length - 1:
                    "Invalid yieldToUnderlying UniV3 fee path length"
                yieldToUnderlyingUniV3AddressPath[0].equals(yieldTokenEVMAddress):
                    "yieldToUnderlying UniV3 path must start with yield token"
                debtToCollateralUniV3AddressPath.length > 1:
                    "Invalid debtToCollateral UniV3 path length"
                debtToCollateralUniV3FeePath.length == debtToCollateralUniV3AddressPath.length - 1:
                    "Invalid debtToCollateral UniV3 fee path length"
                debtToCollateralUniV3AddressPath[0].equals(yieldToUnderlyingUniV3AddressPath[yieldToUnderlyingUniV3AddressPath.length - 1]):
                    "debtToCollateral UniV3 path must start with the underlying asset (end of yieldToUnderlying path)"
            }
            self.yieldTokenEVMAddress = yieldTokenEVMAddress
            self.yieldToUnderlyingUniV3AddressPath = yieldToUnderlyingUniV3AddressPath
            self.yieldToUnderlyingUniV3FeePath = yieldToUnderlyingUniV3FeePath
            self.debtToCollateralUniV3AddressPath = debtToCollateralUniV3AddressPath
            self.debtToCollateralUniV3FeePath = debtToCollateralUniV3FeePath
        }
    }

    /// This strategy uses FUSDEV vault (Morpho ERC4626).
    /// Deposits collateral into a single FlowALP position, borrowing PYUSD0 as debt.
    /// PYUSD0 is deposited directly into the Morpho FUSDEV ERC4626 vault (no AMM swap needed
    /// since PYUSD0 is the vault's underlying asset).
    /// Each strategy instance holds exactly one collateral type and one debt type (PYUSD0).
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
        /// Closes the underlying FlowALP position by pre-repaying all debt and recovering collateral.
        ///
        /// This method:
        /// 1. Reads outstanding PYUSD0 debt from the FlowALP position
        /// 2. Computes total debt amount
        /// 3. Early-exits with empty sources when debt is zero
        /// 4. Creates an external yield-token source from the AutoBalancer
        /// 5. Reconstructs the yield→PYUSD0 swapper from stored CollateralConfig
        /// 6. Pre-repays the full debt: redeems FUSDEV shares → PYUSD0 (supplementing from
        ///    collateral if needed) and deposits into the position before closePosition is called
        /// 7. Closes the FlowALP position (no repayment sources needed — debt already zero)
        /// 8. Recovers collateral from result vaults; swaps any PYUSD0 overpayment dust to collateral
        /// 9. Drains remaining FUSDEV shares (surplus yield) from the AutoBalancer → collateral
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

            // Step 5: Reconstruct yield→PYUSD0 swapper from stored CollateralConfig.
            let closeCollateralConfig = self._getStoredCollateralConfig(
                strategyType: Type<@FUSDEVStrategy>(),
                collateralType: collateralType
            ) ?? panic("No CollateralConfig for FUSDEVStrategy with \(collateralType.identifier)")
            let closeTokens = FlowYieldVaultsStrategiesV2._resolveTokenBundle(
                yieldTokenEVMAddress: closeCollateralConfig.yieldTokenEVMAddress
            )
            let yieldToPyusd0Swapper = self._buildYieldToDebtSwapper(
                tokens: closeTokens,
                uniqueID: self.uniqueID!
            )

            // Step 6: Pre-repay the full PYUSD0 debt BEFORE calling closePosition.
            //
            // FlowALP stores debt as UFix64 (8-decimal), but PYUSD0 is a 6-decimal ERC-20.
            // Any repayment via SwapSource is floor-truncated to 6 decimals, so it can never
            // exactly satisfy a debt with sub-6-decimal precision — causing an assertion failure
            // in FlowALPv0._repayDebtsFromSources ("needed X.XXXXXXXX, got X.XXXXXX00").
            //
            // Fix: explicitly zero out the PYUSD0 debt by depositing ceil(totalDebtAmount) PYUSD0
            // into the position BEFORE calling closePosition. FlowALP's recordDeposit handles
            // overpayment gracefully: if deposited > debt, the excess becomes a tiny Credit
            // (< 0.000001 PYUSD0) that closePosition returns as an extra vault.
            //
            // Strategy:
            //   (a) Redeem FUSDEV shares to produce totalDebtCeil PYUSD0 (normally covers the debt).
            //   (b) If yield alone can't cover totalDebtCeil, supplement the remainder from collateral.
            //   (c) Deposit all PYUSD0 into the position — debt is now 0; closePosition needs no sources.
            //
            // Step 9 drains any remaining FUSDEV shares (surplus yield not consumed here) separately.
            let pyusd0Unit: UFix64 = 0.000001
            let totalDebtRem = totalDebtAmount % pyusd0Unit
            let totalDebtCeil = totalDebtRem == 0.0
                ? totalDebtAmount
                : totalDebtAmount - totalDebtRem + pyusd0Unit

            let yieldAvail = yieldTokenSource.minimumAvailable()

            // Step 6a: Redeem FUSDEV shares to cover as much of totalDebtCeil as possible.
            var pyusd0ForDebt <- DeFiActionsUtils.getEmptyVault(yieldToPyusd0Swapper.outType())
            if yieldAvail > 0.0 {
                let yieldToDebtQuote = yieldToPyusd0Swapper.quoteIn(forDesired: totalDebtCeil, reverse: false)
                if yieldToDebtQuote.inAmount > 0.0 {
                    let yieldFunds <- yieldTokenSource.withdrawAvailable(maxAmount: yieldToDebtQuote.inAmount)
                    if yieldFunds.balance > 0.0 {
                        let swapQuote = yieldToPyusd0Swapper.quoteOut(forProvided: yieldFunds.balance, reverse: false)
                        let fromYield <- yieldToPyusd0Swapper.swap(quote: swapQuote, inVault: <-yieldFunds)
                        pyusd0ForDebt.deposit(from: <-fromYield)
                    } else {
                        Burner.burn(<-yieldFunds)
                    }
                }
            }

            // Step 6b: Supplement from collateral if FUSDEV yield didn't fully cover totalDebtCeil.
            if pyusd0ForDebt.balance < totalDebtCeil {
                let collateralToPyusd0Swapper = self._buildCollateralToDebtSwapper(
                    collateralConfig: closeCollateralConfig,
                    tokens: closeTokens,
                    collateralType: collateralType,
                    uniqueID: self.uniqueID!
                )
                let remaining = totalDebtCeil - pyusd0ForDebt.balance
                let collateralQuote = collateralToPyusd0Swapper.quoteIn(forDesired: remaining, reverse: false)
                assert(collateralQuote.inAmount > 0.0,
                    message: "FUSDEVStrategy closePosition: collateral→PYUSD0 quote returned zero — swapper misconfigured")
                let extraCollateral <- self.source.withdrawAvailable(maxAmount: collateralQuote.inAmount)
                assert(extraCollateral.balance > 0.0,
                    message: "FUSDEVStrategy closePosition: no collateral available to cover debt of \(totalDebtCeil) PYUSD0")
                let extraPyusd0 <- collateralToPyusd0Swapper.swap(quote: collateralQuote, inVault: <-extraCollateral)
                pyusd0ForDebt.deposit(from: <-extraPyusd0)
            }

            assert(pyusd0ForDebt.balance >= totalDebtCeil,
                message: "FUSDEVStrategy closePosition: pre-repayment insufficient: have \(pyusd0ForDebt.balance), need \(totalDebtCeil)")

            // Step 6c: Deposit into position — zeroes the debt (FlowALP records any excess < 0.000001
            // PYUSD0 as a Credit, which closePosition returns and Step 9 handles as dust).
            self.position.deposit(from: <-pyusd0ForDebt)

            // Step 7: Close position — debt is fully pre-repaid; no repayment sources needed.
            let resultVaults <- self.position.closePosition(repaymentSources: [])

            // Step 8: Recover collateral from result vaults; swap any PYUSD0 overpayment dust back
            // to collateral. closePosition returns vaults in dict-iteration order (hash-based), so
            // we cannot assume the collateral vault is first. Reconstruct PYUSD0→collateral swapper
            // from CollateralConfig to handle the dust vault (< 0.000001 PYUSD0 from the ceil
            // overpayment in Step 6c).
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

            // Step 9: Drain any remaining FUSDEV shares from the AutoBalancer — surplus yield
            // not consumed by Step 6a (which only withdrew enough shares to cover totalDebtCeil) —
            // and convert them directly to collateral.
            //
            // Use a MultiSwapper so the best available route is chosen:
            //   - Direct: FUSDEV → collateral via the stored yieldToCollateral AMM path (works
            //     even for 2-element paths where a direct yield↔collateral pool exists)
            //   - 2-hop:  FUSDEV → PYUSD0 → collateral (via yieldToPyusd0 + debtToCollateral)
            let excessShares <- yieldTokenSource.withdrawAvailable(maxAmount: UFix64.max)
            if excessShares.balance > 0.0 {
                let yieldToCollateralDirect = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                    tokenPath: closeCollateralConfig.yieldToCollateralUniV3AddressPath,
                    feePath: closeCollateralConfig.yieldToCollateralUniV3FeePath,
                    inVault: closeTokens.yieldTokenType,
                    outVault: collateralType,
                    uniqueID: self.uniqueID!
                )
                let yieldToCollateralViaDebt = SwapConnectors.SequentialSwapper(
                    swappers: [yieldToPyusd0Swapper, debtToCollateralSwapper],
                    uniqueID: self.copyID()
                )
                let sharesToCollateral = SwapConnectors.MultiSwapper(
                    inVault: closeTokens.yieldTokenType,
                    outVault: collateralType,
                    swappers: [yieldToCollateralDirect, yieldToCollateralViaDebt],
                    uniqueID: self.copyID()
                )
                let quote = sharesToCollateral.quoteOut(forProvided: excessShares.balance, reverse: false)
                if quote.outAmount > 0.0 {
                    let extraCollateral <- sharesToCollateral.swap(quote: quote, inVault: <-excessShares)
                    collateralVault.deposit(from: <-extraCollateral)
                } else {
                    emit DustBurned(
                        tokenType: excessShares.getType().identifier,
                        balance: excessShares.balance,
                        quoteInType: quote.inType.identifier,
                        quoteOutType: quote.outType.identifier,
                        quoteInAmount: quote.inAmount,
                        quoteOutAmount: quote.outAmount,
                        swapperType: sharesToCollateral.getType().identifier
                    )
                    Burner.burn(<-excessShares)
                }
            } else {
                Burner.burn(<-excessShares)
            }

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

        /// Builds a YIELD→PYUSD0 MultiSwapper (AMM direct + ERC4626 redeem path).
        /// PYUSD0 is the underlying asset of the FUSDEV vault and is also the debt token.
        access(self) fun _buildYieldToDebtSwapper(
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            // Direct FUSDEV→PYUSD0 via AMM (fee 100)
            let yieldToDebtAMM = FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: [tokens.yieldTokenEVMAddress, tokens.underlying4626AssetEVMAddress],
                feePath: [100],
                inVault: tokens.yieldTokenType,
                outVault: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )
            // FUSDEV→PYUSD0 via Morpho ERC4626 redeem (no additional swap needed)
            let yieldToUnderlying = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: true
            )
            return SwapConnectors.MultiSwapper(
                inVault: tokens.yieldTokenType,
                outVault: tokens.underlying4626AssetType,
                swappers: [yieldToDebtAMM, yieldToUnderlying],
                uniqueID: uniqueID
            )
        }

        /// Builds a collateral→PYUSD0 UniV3 swapper from CollateralConfig.
        /// Derives the path by reversing yieldToCollateralUniV3AddressPath[1..] (skipping the
        /// yield token); PYUSD0 is the underlying asset and the debt token, so no further hop needed.
        /// e.g. [FUSDEV, PYUSD0, WETH, WBTC] → [WBTC, WETH, PYUSD0]
        access(self) fun _buildCollateralToDebtSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            let yieldToCollPath = collateralConfig.yieldToCollateralUniV3AddressPath
            let yieldToCollFees = collateralConfig.yieldToCollateralUniV3FeePath
            // Requires at least 3 elements: [yield, PYUSD0 (debt/underlying), collateral, ...].
            // PYUSD0 must be at index 1 — it is the debt token and the derivation logic below
            // assumes it as the starting point of the collateral→debt path. A direct yield↔collateral
            // pool (2-element path) would omit PYUSD0 entirely and is structurally incompatible.
            assert(yieldToCollPath.length >= 3, message: "yieldToCollateral path must have at least 3 elements [yield, PYUSD0, collateral] — a direct yield↔collateral pool is incompatible with FUSDEVStrategy debt routing")
            // Build reversed path: iterate yieldToCollPath from last down to index 1 (skip yield token at 0).
            // e.g. [FUSDEV, PYUSD0, WETH, WBTC] → [WBTC, WETH, PYUSD0]
            var collToDebtPath: [EVM.EVMAddress] = []
            var collToDebtFees: [UInt32] = []
            for i in InclusiveRange(yieldToCollPath.length - 1, 1, step: -1) {
                collToDebtPath.append(yieldToCollPath[i])
            }
            // Build reversed fees: iterate from last down to index 1 (skip yield→underlying fee at 0).
            // e.g. [100, 3000, 3000] → [3000, 3000]
            for i in InclusiveRange(yieldToCollFees.length - 1, 1, step: -1) {
                collToDebtFees.append(yieldToCollFees[i])
            }
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: collToDebtPath,
                feePath: collToDebtFees,
                inVault: collateralType,
                outVault: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )
        }

        /// Builds a PYUSD0→collateral UniV3 swapper for overpayment dust handling.
        /// Uses the yieldToCollateral path[1..] (skipping the yield token at index 0),
        /// going directly from PYUSD0 (the debt/underlying token) to collateral.
        /// e.g. [FUSDEV, PYUSD0, WETH] fees [100, 3000] → [PYUSD0, WETH] fees [3000]
        access(self) fun _buildDebtToCollateralSwapper(
            collateralConfig: FlowYieldVaultsStrategiesV2.CollateralConfig,
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            let path = collateralConfig.yieldToCollateralUniV3AddressPath
            let fees = collateralConfig.yieldToCollateralUniV3FeePath
            // Requires at least 3 elements: [yield, PYUSD0 (debt/underlying), collateral, ...].
            // PYUSD0 must be at index 1 — it is the debt token and the derivation logic below
            // assumes it as the starting point of the debt→collateral path. A direct yield↔collateral
            // pool (2-element path) would omit PYUSD0 entirely and is structurally incompatible.
            assert(path.length >= 3, message: "yieldToCollateral path must have at least 3 elements [yield, PYUSD0, collateral] — a direct yield↔collateral pool is incompatible with FUSDEVStrategy debt routing")
            // Skip the yield token at index 0; path[1..] starts at PYUSD0 (the underlying/debt token).
            var pyusd0ToCollPath: [EVM.EVMAddress] = []
            var pyusd0ToCollFees: [UInt32] = []
            for i in InclusiveRange(1, path.length - 1) {
                pyusd0ToCollPath.append(path[i])
            }
            for i in InclusiveRange(1, fees.length - 1) {
                pyusd0ToCollFees.append(fees[i])
            }
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: pyusd0ToCollPath,
                feePath: pyusd0ToCollFees,
                inVault: tokens.underlying4626AssetType,
                outVault: collateralType,
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
        /// Tracks whether the underlying FlowALP position has been closed.
        /// NOTE: FUSDEVStrategy stores this flag in the contract-level "closedPositions" config
        /// partition (via _isPositionClosed / _markPositionClosed) because FUSDEVStrategy was
        /// already deployed on-chain when that tracking was introduced, and Cadence does not allow
        /// adding fields to existing deployed resources. syWFLOWvStrategy was added after that
        /// point and can therefore carry the flag as a plain resource field.
        access(self) var positionClosed: Bool

        init(
            id: DeFiActions.UniqueIdentifier,
            collateralType: Type,
            position: @FlowALPv0.Position
        ) {
            self.uniqueID = id
            self.sink = position.createSink(type: collateralType)
            self.source = position.createSourceWithOptions(type: collateralType, pullFromTopUpSource: true)
            self.positionClosed = false
            self.position <-position
        }

        // Inherited from FlowYieldVaults.Strategy default implementation
        // access(all) view fun isSupportedCollateralType(_ type: Type): Bool

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return { self.sink.getSinkType(): true }
        }
        /// Returns the amount available for withdrawal via the inner Source
        access(all) fun availableBalance(ofToken: Type): UFix64 {
            if self.positionClosed { return 0.0 }
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
        }
        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference.
        /// FLOW cannot be used as collateral — it is the vault's underlying asset (the debt token).
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                from.getType() == self.sink.getSinkType():
                    "syWFLOWvStrategy position only accepts \(self.sink.getSinkType().identifier) as collateral, got \(from.getType().identifier)"
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
        /// Closes the underlying FlowALP position by preparing FLOW repayment funds from AutoBalancer
        /// (via the stored yield→FLOW swapper) and closing with them.
        access(FungibleToken.Withdraw) fun closePosition(collateralType: Type): @{FungibleToken.Vault} {
            pre {
                self.isSupportedCollateralType(collateralType):
                "Unsupported collateral type \(collateralType.identifier)"
            }
            post {
                result.getType() == collateralType: "Withdraw Vault (\(result.getType().identifier)) is not of a requested collateral type (\(collateralType.identifier))"
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
                self.positionClosed = true
                return <- collateralVault
            }

            // Step 3: Reconstruct MoreERC4626CollateralConfig and swappers from contract-level config.
            let closeConfig = self._getStoredMoreERC4626Config(
                strategyType: Type<@syWFLOWvStrategy>(),
                collateralType: collateralType
            ) ?? panic("No MoreERC4626CollateralConfig for syWFLOWvStrategy with \(collateralType.identifier)")
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
                collateralType: collateralType,
                uniqueID: self.uniqueID!
            )

            // Step 4: Create external syWFLOWv source from AutoBalancer
            let yieldTokenSource = FlowYieldVaultsAutoBalancersV1.createExternalSource(id: self.id()!)
                ?? panic("Could not create external source from AutoBalancer")

            // Step 5: Create a SwapSource that converts syWFLOWv → FLOW for debt repayment.
            // SwapSource uses quoteIn when yield value >= debt (pulling only the needed shares),
            // or quoteOut when yield is insufficient (pulling everything as a best-effort).
            // Any FLOW overpayment is returned as dust and converted back to collateral below.
            let flowSource = SwapConnectors.SwapSource(
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
                let quote = flowToCollateral.quoteIn(forDesired: shortfall, reverse: true)
                assert(quote.inAmount > 0.0,
                    message: "Pre-supplement: collateral→FLOW quote returned zero input for non-zero shortfall — swapper misconfigured")
                let extraCollateral <- self.source.withdrawAvailable(maxAmount: quote.inAmount)
                assert(extraCollateral.balance > 0.0,
                    message: "Pre-supplement: no collateral available to cover shortfall of \(shortfall) FLOW")
                let extraFlow <- flowToCollateral.swapBack(quote: quote, residual: <-extraCollateral)
                assert(extraFlow.balance >= shortfall,
                    message: "Pre-supplement: collateral→FLOW swap produced less than shortfall: got \(extraFlow.balance), need \(shortfall)")
                self.position.deposit(from: <-extraFlow)
            }

            // Step 7: Close position — pool pulls the (now pre-reduced) FLOW debt from flowSource
            let resultVaults <- self.position.closePosition(repaymentSources: [flowSource])

            // closePosition returns vaults in dict-iteration order (hash-based), so we cannot
            // assume the collateral vault is first. Iterate all vaults: collect collateral by type
            // and convert any non-collateral vaults (FLOW overpayment dust) back to collateral.
            var collateralVault <- DeFiActionsUtils.getEmptyVault(collateralType)
            while resultVaults.length > 0 {
                let v <- resultVaults.removeFirst()
                if v.getType() == collateralType {
                    collateralVault.deposit(from: <-v)
                } else if v.balance == 0.0 {
                    // destroy empty vault
                    Burner.burn(<-v)
                } else {
                    // FLOW overpayment dust — convert back to collateral if routable
                    let quote = flowToCollateral.quoteOut(forProvided: v.balance, reverse: false)
                    if quote.outAmount > 0.0 {
                        let swapped <- flowToCollateral.swap(quote: quote, inVault: <-v)
                        collateralVault.deposit(from: <-swapped)
                    } else {
                        emit DustBurned(
                            tokenType: v.getType().identifier,
                            balance: v.balance,
                            quoteInType: quote.inType.identifier,
                            quoteOutType: quote.outType.identifier,
                            quoteInAmount: quote.inAmount,
                            quoteOutAmount: quote.outAmount,
                            swapperType: flowToCollateral.getType().identifier
                        )
                        Burner.burn(<-v)
                    }
                }
            }

            destroy resultVaults

            // Step 8: Drain any remaining syWFLOWv shares from the AutoBalancer — excess yield
            // not consumed during debt repayment — and convert them directly to collateral.
            // The SwapSource inside closePosition only pulled what was needed to repay the debt;
            // any surplus shares are still held by the AutoBalancer and are recovered here.
            let excessShares <- yieldTokenSource.withdrawAvailable(maxAmount: UFix64.max)
            if excessShares.balance > 0.0 {
                let sharesToCollateral = SwapConnectors.SequentialSwapper(
                    swappers: [syWFLOWvToFlow, flowToCollateral],
                    uniqueID: self.copyID()
                )
                let quote = sharesToCollateral.quoteOut(forProvided: excessShares.balance, reverse: false)
                if quote.outAmount > 0.0 {
                    let extraCollateral <- sharesToCollateral.swap(quote: quote, inVault: <-excessShares)
                    collateralVault.deposit(from: <-extraCollateral)
                } else {
                    emit DustBurned(
                        tokenType: excessShares.getType().identifier,
                        balance: excessShares.balance,
                        quoteInType: quote.inType.identifier,
                        quoteOutType: quote.outType.identifier,
                        quoteInAmount: quote.inAmount,
                        quoteOutAmount: quote.outAmount,
                        swapperType: sharesToCollateral.getType().identifier
                    )
                    Burner.burn(<-excessShares)
                }
            } else {
                Burner.burn(<-excessShares)
            }

            self.positionClosed = true
            return <- collateralVault
        }
        /// Executed when a Strategy is burned, cleaning up the Strategy's stored AutoBalancer and contract-level config entries
        access(contract) fun burnCallback() {
            FlowYieldVaultsAutoBalancersV1._cleanupAutoBalancer(id: self.id()!)
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

        /// Builds a FLOW→collateral UniV3 swapper from MoreERC4626CollateralConfig.
        access(self) fun _buildFlowToCollateralSwapper(
            closeConfig: FlowYieldVaultsStrategiesV2.MoreERC4626CollateralConfig,
            closeTokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            collateralType: Type,
            uniqueID: DeFiActions.UniqueIdentifier
        ): UniswapV3SwapConnectors.Swapper {
            return FlowYieldVaultsStrategiesV2._buildUniV3Swapper(
                tokenPath: closeConfig.debtToCollateralUniV3AddressPath,
                feePath: closeConfig.debtToCollateralUniV3FeePath,
                inVault: closeTokens.underlying4626AssetType,  // FLOW
                outVault: collateralType,
                uniqueID: uniqueID
            )
        }
    }

    access(all) struct TokenBundle {
        /// @deprecated — retained for Cadence upgrade compatibility; populated with placeholder values and not read.
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

    /// Resolves the token bundle for a strategy given the ERC4626 yield vault address.
    /// moetTokenType/moetTokenEVMAddress are retained in TokenBundle for Cadence upgrade
    /// compatibility (struct fields cannot be removed once deployed) but are no longer used —
    /// the yield token address is passed as a placeholder to avoid unnecessary EVM lookups.
    access(self) fun _resolveTokenBundle(yieldTokenEVMAddress: EVM.EVMAddress): FlowYieldVaultsStrategiesV2.TokenBundle {
        let yieldTokenType = FlowEVMBridgeConfig.getTypeAssociated(with: yieldTokenEVMAddress)
            ?? panic("Could not retrieve the VM Bridge associated Type for the yield token address \(yieldTokenEVMAddress.toString())")

        let underlying4626AssetEVMAddress = ERC4626Utils.underlyingAssetEVMAddress(vault: yieldTokenEVMAddress)
            ?? panic("Could not get the underlying asset's EVM address for ERC4626Vault \(yieldTokenEVMAddress.toString())")
        let underlying4626AssetType = FlowEVMBridgeConfig.getTypeAssociated(with: underlying4626AssetEVMAddress)
            ?? panic("Could not retrieve the VM Bridge associated Type for the ERC4626 underlying asset \(underlying4626AssetEVMAddress.toString())")

        return FlowYieldVaultsStrategiesV2.TokenBundle(
            moetTokenType: yieldTokenType,           // unused placeholder
            moetTokenEVMAddress: yieldTokenEVMAddress, // unused placeholder
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
            // FUSDEVStrategy: borrows PYUSD0 from the FlowALP position, deposits into FUSDEV
            // -----------------------------------------------------------------------
            case Type<@FUSDEVStrategy>():
                // Reject PYUSD0 as collateral — it is the vault's underlying / debt token
                assert(
                    collateralType != tokens.underlying4626AssetType,
                    message: "FUSDEVStrategy: PYUSD0 cannot be used as collateral — it is the vault's underlying asset"
                )

                // Swappers: PYUSD0 (underlying/debt) <-> YIELD (FUSDEV)
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
            // Direct PYUSD0 → FUSDEV via AMM (fee 100)
            let debtToYieldAMM = self._createUniV3Swapper(
                tokenPath: [tokens.underlying4626AssetEVMAddress, tokens.yieldTokenEVMAddress],
                feePath: [100],
                inVault: tokens.underlying4626AssetType,
                outVault: tokens.yieldTokenType,
                uniqueID: uniqueID
            )

            // PYUSD0 → FUSDEV via Morpho ERC4626 vault deposit (no AMM swap needed)
            let underlyingTo4626 = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: false
            )

            return SwapConnectors.MultiSwapper(
                inVault: tokens.underlying4626AssetType,
                outVault: tokens.yieldTokenType,
                swappers: [debtToYieldAMM, underlyingTo4626],
                uniqueID: uniqueID
            )
        }

        access(self) fun _createYieldToDebtSwapper(
            tokens: FlowYieldVaultsStrategiesV2.TokenBundle,
            uniqueID: DeFiActions.UniqueIdentifier
        ): SwapConnectors.MultiSwapper {
            // Direct FUSDEV → PYUSD0 via AMM (fee 100)
            let yieldToDebtAMM = self._createUniV3Swapper(
                tokenPath: [tokens.yieldTokenEVMAddress, tokens.underlying4626AssetEVMAddress],
                feePath: [100],
                inVault: tokens.yieldTokenType,
                outVault: tokens.underlying4626AssetType,
                uniqueID: uniqueID
            )

            // FUSDEV → PYUSD0 via Morpho ERC4626 redeem (no additional AMM swap needed)
            let yieldToUnderlying = MorphoERC4626SwapConnectors.Swapper(
                vaultEVMAddress: tokens.yieldTokenEVMAddress,
                coa: FlowYieldVaultsStrategiesV2._getCOACapability(),
                feeSource: FlowYieldVaultsStrategiesV2._createFeeSource(withID: uniqueID),
                uniqueID: uniqueID,
                isReversed: true
            )

            return SwapConnectors.MultiSwapper(
                inVault: tokens.yieldTokenType,
                outVault: tokens.underlying4626AssetType,
                swappers: [yieldToDebtAMM, yieldToUnderlying],
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

        /// Creates a Collateral → Debt (PYUSD0) swapper using UniswapV3.
        /// Path: collateral → underlying (PYUSD0)
        ///
        /// The fee for collateral→underlying is the last fee in yieldToCollateral (reversed).
        /// Used by FUSDEVStrategy.closePosition to pre-reduce position debt from
        /// collateral when yield tokens alone cannot cover the full outstanding PYUSD0 debt.
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
            // underlying (PYUSD0) EVM address = second element of yieldToCollateral path (index 1)
            assert(yieldToCollPath.length >= 2, message: "yieldToCollateral path must have at least 2 elements")
            let collateralEVMAddress = yieldToCollPath[yieldToCollPath.length - 1]
            let underlyingEVMAddress = tokens.underlying4626AssetEVMAddress

            // fee = collateral→PYUSD0 = last fee in yieldToCollateral (reversed)
            let collateralToUnderlyingFee = yieldToCollFees[yieldToCollFees.length - 1]

            return self._createUniV3Swapper(
                tokenPath: [collateralEVMAddress, underlyingEVMAddress],
                feePath: [collateralToUnderlyingFee],
                inVault: collateralType,
                outVault: tokens.underlying4626AssetType,
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

                // For syWFLOWvStrategy the debt token IS the underlying asset (FLOW).
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

                return <-create syWFLOWvStrategy(
                    id: uniqueID,
                    collateralType: collateralType,
                    position: <-positionFlow
                )

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
                return <- create MorphoERC4626StrategyComposer(
                    self.configs[type] ?? panic("No config registered for \(type.identifier)")
                )
            case Type<@MoreERC4626StrategyComposer>():
                let moreCfg = FlowYieldVaultsStrategiesV2._getMoreERC4626ComposerConfig(type)
                assert(moreCfg.length > 0, message: "No config registered for \(type.identifier)")
                return <- create MoreERC4626StrategyComposer(moreCfg)
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

            let base = CollateralConfig(
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                yieldToCollateralUniV3AddressPath: yieldToCollateralAddressPath,
                yieldToCollateralUniV3FeePath: yieldToCollateralFeePath
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

            let cfg = MoreERC4626CollateralConfig(
                yieldTokenEVMAddress: yieldTokenEVMAddress,
                yieldToUnderlyingUniV3AddressPath: yieldToUnderlyingAddressPath,
                yieldToUnderlyingUniV3FeePath: yieldToUnderlyingFeePath,
                debtToCollateralUniV3AddressPath: debtToCollateralAddressPath,
                debtToCollateralUniV3FeePath: debtToCollateralFeePath
            )
            self.upsertMoreERC4626Config(config: { strategyType: { collateralVaultType: cfg } })
        }

        access(Configure) fun purgeConfig() {
            self.configs = {
                Type<@MorphoERC4626StrategyComposer>(): {
                    Type<@FUSDEVStrategy>(): {} as {Type: CollateralConfig}
                }
            }
            FlowYieldVaultsStrategiesV2._purgeMoreERC4626Configs()
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
