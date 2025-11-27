// standards
import "Burner"
import "FungibleToken"
// DeFiActions
import "DeFiActions"
import "FlowTransactionScheduler"
// Registry for global tide mapping
import "FlowVaultsSchedulerRegistry"

/// FlowVaultsAutoBalancers
///
/// This contract deals with the storage, retrieval and cleanup of DeFiActions AutoBalancers as they are used in
/// FlowVaults defined Strategies.
///
/// AutoBalancers are stored in contract account storage at paths derived by their related DeFiActions.UniqueIdentifier.id
/// which identifies all DeFiActions components in the stack related to their composite Strategy.
///
/// When a Tide and necessarily the related Strategy is closed & burned, the related AutoBalancer and its Capabilities
/// are destroyed and deleted.
///
/// Scheduling approach:
/// - AutoBalancers are configured with a recurringConfig at creation
/// - After creation, scheduleNextRebalance(nil) starts the self-scheduling chain
/// - The registry tracks all live tide IDs for global mapping
/// - Cleanup unregisters from the registry
///
access(all) contract FlowVaultsAutoBalancers {

    /// The path prefix used for StoragePath & PublicPath derivations
    access(all) let pathPrefix: String

    /* --- PUBLIC METHODS --- */

    /// Returns the path (StoragePath or PublicPath) at which an AutoBalancer is stored with the associated
    /// UniqueIdentifier.id.
    access(all) view fun deriveAutoBalancerPath(id: UInt64, storage: Bool): Path {
        return storage ? StoragePath(identifier: "\(self.pathPrefix)\(id)")! : PublicPath(identifier: "\(self.pathPrefix)\(id)")!
    }

    /// Returns an unauthorized reference to an AutoBalancer with the given UniqueIdentifier.id value. If none is
    /// configured, `nil` will be returned.
    access(all) fun borrowAutoBalancer(id: UInt64): &DeFiActions.AutoBalancer? {
        let publicPath = self.deriveAutoBalancerPath(id: id, storage: false) as! PublicPath
        return self.account.capabilities.borrow<&DeFiActions.AutoBalancer>(publicPath)
    }

    /// Checks if an AutoBalancer has at least one active (Scheduled) transaction.
    /// Used by Supervisor to detect stuck tides that need recovery.
    ///
    /// @param id: The tide/AutoBalancer ID
    /// @return Bool: true if there's at least one Scheduled transaction, false otherwise
    ///
    access(all) fun hasActiveSchedule(id: UInt64): Bool {
        let autoBalancer = self.borrowAutoBalancer(id: id)
        if autoBalancer == nil {
            return false
        }
        
        let txnIDs = autoBalancer!.getScheduledTransactionIDs()
        for txnID in txnIDs {
            if let txnRef = autoBalancer!.borrowScheduledTransaction(id: txnID) {
                if txnRef.status() == FlowTransactionScheduler.Status.Scheduled {
                    return true
                }
            }
        }
        return false
    }

    /// Checks if an AutoBalancer is overdue for execution.
    /// A tide is considered overdue if:
    /// - It has a recurring config
    /// - The next expected execution time has passed
    /// - It has no active schedule
    ///
    /// @param id: The tide/AutoBalancer ID
    /// @return Bool: true if tide is overdue and stuck, false otherwise
    ///
    access(all) fun isStuckTide(id: UInt64): Bool {
        let autoBalancer = self.borrowAutoBalancer(id: id)
        if autoBalancer == nil {
            return false
        }
        
        // Check if tide has recurring config (should be executing periodically)
        let config = autoBalancer!.getRecurringConfig()
        if config == nil {
            return false // Not configured for recurring, can't be "stuck"
        }
        
        // Check if there's an active schedule
        if self.hasActiveSchedule(id: id) {
            return false // Has active schedule, not stuck
        }
        
        // Check if tide is overdue
        let nextExpected = autoBalancer!.calculateNextExecutionTimestampAsConfigured()
        if nextExpected == nil {
            return true // Can't calculate next time, likely stuck
        }
        
        // If next expected time has passed and no active schedule, tide is stuck
        return nextExpected! < getCurrentBlock().timestamp
    }

    /* --- INTERNAL METHODS --- */

    /// Configures a new AutoBalancer in storage, configures its public Capability, and sets its inner authorized
    /// Capability. If an AutoBalancer is stored with an associated UniqueID value, the operation reverts.
    ///
    /// @param oracle: The oracle used to query deposited & withdrawn value and to determine if a rebalance should execute
    /// @param vaultType: The type of Vault wrapped by the AutoBalancer
    /// @param lowerThreshold: The percentage below base value at which a rebalance pulls from rebalanceSource
    /// @param upperThreshold: The percentage above base value at which a rebalance pushes to rebalanceSink
    /// @param rebalanceSink: An optional DeFiActions Sink to which excess value is directed when rebalancing
    /// @param rebalanceSource: An optional DeFiActions Source from which value is withdrawn when rebalancing
    /// @param recurringConfig: Optional configuration for automatic recurring rebalancing via FlowTransactionScheduler
    /// @param uniqueID: The DeFiActions UniqueIdentifier used for identifying this AutoBalancer
    ///
    access(account) fun _initNewAutoBalancer(
        oracle: {DeFiActions.PriceOracle},
        vaultType: Type,
        lowerThreshold: UFix64,
        upperThreshold: UFix64,
        rebalanceSink: {DeFiActions.Sink}?,
        rebalanceSource: {DeFiActions.Source}?,
        recurringConfig: DeFiActions.AutoBalancerRecurringConfig?,
        uniqueID: DeFiActions.UniqueIdentifier
    ): auth(DeFiActions.Auto, DeFiActions.Set, DeFiActions.Get, DeFiActions.Schedule, FungibleToken.Withdraw) &DeFiActions.AutoBalancer {

        // derive paths & prevent collision
        let storagePath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: true) as! StoragePath
        let publicPath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: false) as! PublicPath
        var storedType = self.account.storage.type(at: storagePath)
        var publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == nil,
            message: "Storage collision when creating AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(!publishedCap,
            message: "Published Capability collision found when publishing AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")

        // create & save AutoBalancer with optional recurring config
        let autoBalancer <- DeFiActions.createAutoBalancer(
                oracle: oracle,
                vaultType: vaultType,
                lowerThreshold: lowerThreshold,
                upperThreshold: upperThreshold,
                rebalanceSink: rebalanceSink,
                rebalanceSource: rebalanceSource,
                recurringConfig: recurringConfig,
                uniqueID: uniqueID
            )
        self.account.storage.save(<-autoBalancer, to: storagePath)
        let autoBalancerRef = self._borrowAutoBalancer(uniqueID.id)

        // issue & publish public capability
        let publicCap = self.account.capabilities.storage.issue<&DeFiActions.AutoBalancer>(storagePath)
        self.account.capabilities.publish(publicCap, at: publicPath)

        // issue private capability & set within AutoBalancer
        let authorizedCap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute) &DeFiActions.AutoBalancer>(storagePath)
        autoBalancerRef.setSelfCapability(authorizedCap)

        // ensure proper configuration before closing
        storedType = self.account.storage.type(at: storagePath)
        publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == Type<@DeFiActions.AutoBalancer>(),
            message: "Error when configuring AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(publishedCap,
            message: "Error when publishing AutoBalancer Capability for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")

        // Issue handler capability for the AutoBalancer
        let handlerCap = self.account.capabilities.storage
            .issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(storagePath)

        // Register tide in registry for global mapping of live tide IDs
        FlowVaultsSchedulerRegistry.register(tideID: uniqueID.id, handlerCap: handlerCap)

        // Start the native AutoBalancer self-scheduling chain
        // This schedules the first rebalance; subsequent ones are scheduled automatically
        // by the AutoBalancer after each execution (via recurringConfig)
        let scheduleError = autoBalancerRef.scheduleNextRebalance(whileExecuting: nil)
        if scheduleError != nil {
            panic("Failed to schedule first rebalance for AutoBalancer \(uniqueID.id): ".concat(scheduleError!))
        }

        return autoBalancerRef
    }

    /// Returns an authorized reference on the AutoBalancer with the associated UniqueIdentifier.id. If none is found,
    /// the operation reverts.
    access(account)
    fun _borrowAutoBalancer(_ id: UInt64): auth(DeFiActions.Auto, DeFiActions.Set, DeFiActions.Get, DeFiActions.Schedule, FungibleToken.Withdraw) &DeFiActions.AutoBalancer {
        let storagePath = self.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        return self.account.storage.borrow<auth(DeFiActions.Auto, DeFiActions.Set, DeFiActions.Get, DeFiActions.Schedule, FungibleToken.Withdraw) &DeFiActions.AutoBalancer>(
                from: storagePath
            ) ?? panic("Could not borrow reference to AutoBalancer with UniqueIdentifier.id \(id) from StoragePath \(storagePath)")
    }

    /// Called by strategies defined in the FlowVaults account which leverage account-hosted AutoBalancers when a
    /// Strategy is burned
    access(account) fun _cleanupAutoBalancer(id: UInt64) {
        // Unregister from registry (removes from global tide mapping)
        FlowVaultsSchedulerRegistry.unregister(tideID: id)

        let storagePath = self.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        let publicPath = self.deriveAutoBalancerPath(id: id, storage: false) as! PublicPath
        // unpublish the public AutoBalancer Capability
        let _ = self.account.capabilities.unpublish(publicPath)
        
        // Collect controller IDs first (can't modify during iteration)
        var controllersToDelete: [UInt64] = []
        self.account.capabilities.storage.forEachController(forPath: storagePath, fun(_ controller: &StorageCapabilityController): Bool {
            controllersToDelete.append(controller.capabilityID)
            return true
        })
        // Delete controllers after iteration
        for controllerID in controllersToDelete {
            if let controller = self.account.capabilities.storage.getController(byCapabilityID: controllerID) {
                controller.delete()
            }
        }
        
        // load & burn the AutoBalancer (this also handles any pending scheduled transactions via burnCallback)
        let autoBalancer <-self.account.storage.load<@DeFiActions.AutoBalancer>(from: storagePath)
        Burner.burn(<-autoBalancer)
    }

    init() {
        self.pathPrefix = "FlowVaultsAutoBalancer_"
    }
}
