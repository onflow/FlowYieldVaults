// standards
import "FungibleToken"
import "FlowToken"
// Flow system contracts
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
import "FlowVaultsAutoBalancers"
// Proof storage (separate contract)
import "FlowVaultsSchedulerProofs"

/// FlowVaultsScheduler
///
/// This contract enables the scheduling of autonomous rebalancing transactions for FlowVaults Tides.
/// It integrates with Flow's FlowTransactionScheduler to schedule periodic rebalancing operations
/// on AutoBalancers associated with specific Tide IDs.
///
/// Key Features:
/// - Schedule one-time or recurring rebalancing transactions
/// - Cancel scheduled rebalancing transactions
/// - Query scheduled transactions and their status
/// - Estimate scheduling costs before committing funds
///
access(all) contract FlowVaultsScheduler {

    /* --- PATHS --- */

    /// Storage path for the SchedulerManager resource
    access(all) let SchedulerManagerStoragePath: StoragePath
    /// Public path for the SchedulerManager public interface
    access(all) let SchedulerManagerPublicPath: PublicPath

    /* --- EVENTS --- */

    /// Emitted when a rebalancing transaction is scheduled for a Tide
    access(all) event RebalancingScheduled(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        timestamp: UFix64,
        priority: UInt8,
        isRecurring: Bool,
        recurringInterval: UFix64?,
        force: Bool
    )

    /// Emitted when a scheduled rebalancing transaction is canceled
    access(all) event RebalancingCanceled(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        feesReturned: UFix64
    )

    /// Emitted when a scheduled rebalancing transaction is executed
    access(all) event RebalancingExecuted(
        tideID: UInt64,
        scheduledTransactionID: UInt64,
        timestamp: UFix64
    )

    /* --- STRUCTS --- */

    /// RebalancingScheduleInfo contains information about a scheduled rebalancing transaction
    access(all) struct RebalancingScheduleInfo {
        access(all) let tideID: UInt64
        access(all) let scheduledTransactionID: UInt64
        access(all) let timestamp: UFix64
        access(all) let priority: FlowTransactionScheduler.Priority
        access(all) let isRecurring: Bool
        access(all) let recurringInterval: UFix64?
        access(all) let force: Bool
        access(all) let status: FlowTransactionScheduler.Status?

        init(
            tideID: UInt64,
            scheduledTransactionID: UInt64,
            timestamp: UFix64,
            priority: FlowTransactionScheduler.Priority,
            isRecurring: Bool,
            recurringInterval: UFix64?,
            force: Bool,
            status: FlowTransactionScheduler.Status?
        ) {
            self.tideID = tideID
            self.scheduledTransactionID = scheduledTransactionID
            self.timestamp = timestamp
            self.priority = priority
            self.isRecurring = isRecurring
            self.recurringInterval = recurringInterval
            self.force = force
            self.status = status
        }
    }

    /// RebalancingScheduleData is stored internally to track scheduled transactions
    access(all) struct RebalancingScheduleData {
        access(all) let tideID: UInt64
        access(all) let isRecurring: Bool
        access(all) let recurringInterval: UFix64?
        access(all) let force: Bool

        init(
            tideID: UInt64,
            isRecurring: Bool,
            recurringInterval: UFix64?,
            force: Bool
        ) {
            self.tideID = tideID
            self.isRecurring = isRecurring
            self.recurringInterval = recurringInterval
            self.force = force
        }
    }

    /* --- RESOURCES --- */

    /// Wrapper handler that emits a scheduler-level execution event while delegating to the target handler
    access(all) resource RebalancingHandler: FlowTransactionScheduler.TransactionHandler {
        /// Capability pointing at the actual TransactionHandler (AutoBalancer)
        access(self) let target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>
        /// The Tide ID this handler corresponds to
        access(self) let tideID: UInt64

        init(
            target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            tideID: UInt64
        ) {
            self.target = target
            self.tideID = tideID
        }

        /// Called by FlowTransactionScheduler when the scheduled tx executes
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let ref = self.target.borrow()
                ?? panic("Invalid target TransactionHandler capability for Tide #".concat(self.tideID.toString()))
            // delegate to the underlying handler (AutoBalancer)
            ref.executeTransaction(id: id, data: data)
            // record on-chain proof for strict verification without relying on events
            FlowVaultsSchedulerProofs.markExecuted(tideID: self.tideID, scheduledTransactionID: id)
            // emit wrapper-level execution signal for test observability
            emit RebalancingExecuted(
                tideID: self.tideID,
                scheduledTransactionID: id,
                timestamp: getCurrentBlock().timestamp
            )
        }
    }

    /// SchedulerManager manages scheduled rebalancing transactions for multiple Tides
    access(all) resource SchedulerManager {
        /// Maps Tide IDs to their scheduled transaction resources
        access(self) let scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// Maps scheduled transaction IDs to rebalancing schedule data
        access(self) let scheduleData: {UInt64: RebalancingScheduleData}

        init() {
            self.scheduledTransactions <- {}
            self.scheduleData = {}
        }

        /// Schedules a rebalancing transaction for a specific Tide
        ///
        /// @param handlerCap: A capability to the AutoBalancer that implements TransactionHandler
        /// @param tideID: The ID of the Tide to schedule rebalancing for
        /// @param timestamp: The Unix timestamp when the rebalancing should occur
        /// @param priority: The priority level (High, Medium, or Low)
        /// @param executionEffort: The computational effort allocated for execution
        /// @param fees: Flow tokens to pay for the scheduled transaction
        /// @param force: Whether to force rebalancing regardless of thresholds
        /// @param isRecurring: Whether this should be a recurring rebalancing
        /// @param recurringInterval: If recurring, the interval in seconds between executions
        ///
        access(all) fun scheduleRebalancing(
            handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
            tideID: UInt64,
            timestamp: UFix64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            fees: @FlowToken.Vault,
            force: Bool,
            isRecurring: Bool,
            recurringInterval: UFix64?
        ) {
            pre {
                self.scheduledTransactions[tideID] == nil:
                    "Rebalancing is already scheduled for Tide #\(tideID). Cancel the existing schedule first."
                !isRecurring || (isRecurring && recurringInterval != nil && recurringInterval! > 0.0):
                    "Recurring interval must be greater than 0 when isRecurring is true"
                handlerCap.check():
                    "Invalid handler capability provided"
            }

            // Schedule the transaction with force parameter in data
            let data: {String: AnyStruct} = {"force": force}
            let scheduledTx <- FlowTransactionScheduler.schedule(
                handlerCap: handlerCap,
                data: data,
                timestamp: timestamp,
                priority: priority,
                executionEffort: executionEffort,
                fees: <-fees
            )

            // Store the schedule information
            let scheduleInfo = RebalancingScheduleData(
                tideID: tideID,
                isRecurring: isRecurring,
                recurringInterval: recurringInterval,
                force: force
            )
            self.scheduleData[scheduledTx.id] = scheduleInfo

            emit RebalancingScheduled(
                tideID: tideID,
                scheduledTransactionID: scheduledTx.id,
                timestamp: timestamp,
                priority: priority.rawValue,
                isRecurring: isRecurring,
                recurringInterval: recurringInterval,
                force: force
            )

            // Store the scheduled transaction
            self.scheduledTransactions[tideID] <-! scheduledTx
        }

        /// Cancels a scheduled rebalancing transaction for a specific Tide
        ///
        /// @param tideID: The ID of the Tide whose scheduled rebalancing should be canceled
        /// @return The refunded fees
        ///
        access(all) fun cancelRebalancing(tideID: UInt64): @FlowToken.Vault {
            pre {
                self.scheduledTransactions[tideID] != nil:
                    "No scheduled rebalancing found for Tide #\(tideID)"
            }

            // Remove the scheduled transaction
            let scheduledTx <- self.scheduledTransactions.remove(key: tideID)
                ?? panic("Could not remove scheduled transaction for Tide #\(tideID)")

            let txID = scheduledTx.id

            // Cancel the scheduled transaction and get the refund
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-scheduledTx)

            // Clean up the schedule data
            let _removed = self.scheduleData.remove(key: txID)

            emit RebalancingCanceled(
                tideID: tideID,
                scheduledTransactionID: txID,
                feesReturned: refund.balance
            )

            return <-refund
        }

        /// Returns information about all scheduled rebalancing transactions
        access(all) fun getAllScheduledRebalancing(): [RebalancingScheduleInfo] {
            let schedules: [RebalancingScheduleInfo] = []
            
            for tideID in self.scheduledTransactions.keys {
                let txRef = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction?
                if txRef != nil {
                    let data = self.scheduleData[txRef!.id]
                    if data != nil {
                        schedules.append(RebalancingScheduleInfo(
                            tideID: data!.tideID,
                            scheduledTransactionID: txRef!.id,
                            timestamp: txRef!.timestamp,
                            priority: FlowTransactionScheduler.getTransactionData(id: txRef!.id)?.priority
                                ?? FlowTransactionScheduler.Priority.Low,
                            isRecurring: data!.isRecurring,
                            recurringInterval: data!.recurringInterval,
                            force: data!.force,
                            status: FlowTransactionScheduler.getStatus(id: txRef!.id)
                        ))
                    }
                }
            }
            
            return schedules
        }

        /// Returns information about a scheduled rebalancing transaction for a specific Tide
        access(all) fun getScheduledRebalancing(tideID: UInt64): RebalancingScheduleInfo? {
            if let scheduledTx = &self.scheduledTransactions[tideID] as &FlowTransactionScheduler.ScheduledTransaction? {
                if let data = self.scheduleData[scheduledTx.id] {
                    return RebalancingScheduleInfo(
                        tideID: data.tideID,
                        scheduledTransactionID: scheduledTx.id,
                        timestamp: scheduledTx.timestamp,
                        priority: FlowTransactionScheduler.getTransactionData(id: scheduledTx.id)?.priority
                            ?? FlowTransactionScheduler.Priority.Low,
                        isRecurring: data.isRecurring,
                        recurringInterval: data.recurringInterval,
                        force: data.force,
                        status: FlowTransactionScheduler.getStatus(id: scheduledTx.id)
                    )
                }
            }
            return nil
        }

        /// Returns the Tide IDs that have scheduled rebalancing
        access(all) view fun getScheduledTideIDs(): [UInt64] {
            return self.scheduledTransactions.keys
        }
    }

    /* --- PUBLIC FUNCTIONS --- */

    // (Intentionally left blank; public read APIs are in FlowVaultsSchedulerProofs)

    /// Creates a new RebalancingHandler that wraps a target TransactionHandler (AutoBalancer)
    access(all) fun createRebalancingHandler(
        target: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>,
        tideID: UInt64
    ): @RebalancingHandler {
        return <- create RebalancingHandler(target: target, tideID: tideID)
    }

    /// Derives a storage path for a per-tide RebalancingHandler wrapper
    access(all) fun deriveRebalancingHandlerPath(tideID: UInt64): StoragePath {
        let identifier = "FlowVaultsScheduler_RebalancingHandler_".concat(tideID.toString())
        return StoragePath(identifier: identifier)!
    }

    /// Creates a new SchedulerManager resource
    access(all) fun createSchedulerManager(): @SchedulerManager {
        return <- create SchedulerManager()
    }

    /// Estimates the cost of scheduling a rebalancing transaction
    ///
    /// @param timestamp: The desired execution timestamp
    /// @param priority: The priority level
    /// @param executionEffort: The computational effort to allocate
    /// @return An estimate containing the required fee and actual scheduled timestamp
    ///
    access(all) fun estimateSchedulingCost(
        timestamp: UFix64,
        priority: FlowTransactionScheduler.Priority,
        executionEffort: UInt64
    ): FlowTransactionScheduler.EstimatedScheduledTransaction {
        return FlowTransactionScheduler.estimate(
            data: nil,
            timestamp: timestamp,
            priority: priority,
            executionEffort: executionEffort
        )
    }

    /// Returns the scheduler configuration
    access(all) fun getSchedulerConfig(): {FlowTransactionScheduler.SchedulerConfig} {
        return FlowTransactionScheduler.getConfig()
    }

    init() {
        // Initialize paths
        let identifier = "FlowVaultsScheduler_\(self.account.address)"
        self.SchedulerManagerStoragePath = StoragePath(identifier: "\(identifier)_SchedulerManager")!
        self.SchedulerManagerPublicPath = PublicPath(identifier: "\(identifier)_SchedulerManager")!
    }
}

