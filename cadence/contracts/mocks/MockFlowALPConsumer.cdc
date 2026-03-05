import "FungibleToken"

import "DeFiActions"
import "FlowALPv0"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract enabling the persistent storage of a Position similar to a pattern expected for platforms
/// building on top of FlowALP's lending protocol
///
access(all) contract MockFlowALPConsumer {

    /// Canonical path for where the wrapper is to be stored
    access(all) let WrapperStoragePath: StoragePath

    /// Opens a FlowALP Position and returns a PositionWrapper containing that new position.
    /// Requires a pool capability stored at FlowALPv0.PoolCapStoragePath in this contract's account.
    ///
    access(all)
    fun createPositionWrapper(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): @PositionWrapper {
        let poolCap = MockFlowALPConsumer.account.storage.load<Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("Missing pool capability - ensure MockFlowALPConsumer account has a pool capability stored at FlowALPv0.PoolCapStoragePath")
        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Capability")
        let position <- poolRef.createPosition(
            funds: <-collateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: pushToDrawDownSink
        )
        MockFlowALPConsumer.account.storage.save(poolCap, to: FlowALPv0.PoolCapStoragePath)
        return <- create PositionWrapper(position: <-position)
    }

    /// A simple resource encapsulating a FlowALP Position
    access(all) resource PositionWrapper {

        access(self) let position: @FlowALPv0.Position

        init(position: @FlowALPv0.Position) {
            self.position <- position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position
        access(all) fun borrowPosition(): &FlowALPv0.Position {
            return &self.position
        }

        access(all) fun borrowPositionForWithdraw(): auth(FungibleToken.Withdraw) &FlowALPv0.Position {
            return &self.position
        }
    }

    init() {
        self.WrapperStoragePath = /storage/flowALPPositionWrapper
    }
}
