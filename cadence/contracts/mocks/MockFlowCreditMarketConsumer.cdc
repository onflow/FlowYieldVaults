import "FungibleToken"

import "DeFiActions"
import "FlowCreditMarket"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract enabling the persistent storage of a Position similar to a pattern expected for platforms
/// building on top of FlowCreditMarket's lending protocol
///
access(all) contract MockFlowCreditMarketConsumer {

    /// Canonical path for where the wrapper is to be stored
    access(all) let WrapperStoragePath: StoragePath

    /// Opens a FlowCreditMarket Position and returns a PositionWrapper containing that new position
    ///
    access(all)
    fun createPositionWrapper(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): @PositionWrapper {
        return <- create PositionWrapper(
            position: FlowCreditMarket.openPosition(
                collateral: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        )
    }

    /// A simple resource encapsulating a FlowCreditMarket Position
    access(all) resource PositionWrapper {

        access(self) let position: FlowCreditMarket.Position

        init(position: FlowCreditMarket.Position) {
            self.position = position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position
        access(all) fun borrowPosition(): &FlowCreditMarket.Position {
            return &self.position
        }

        access(all) fun borrowPositionForWithdraw(): auth(FungibleToken.Withdraw) &FlowCreditMarket.Position {
            return &self.position
        }
    }

    init() {
        self.WrapperStoragePath = /storage/flowCreditMarketPositionWrapper
    }
}
