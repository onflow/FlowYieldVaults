// standards
import "Burner"
import "ViewResolver"
import "FlowToken"
import "FungibleToken"
import "FlowTransactionScheduler"
// DeFiActions
import "DeFiActions"
import "DeFiActionsUtils"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// [BETA] AutoBalancer
///
/// AutoBalancer provides a resource designed to enable permissionless rebalancing of value around a wrapped Vault.
/// An AutoBalancer can be a critical component of DeFiActions stacks by allowing for strategies to compound, repay
/// loans or direct accumulated value to other sub-systems and/or user Vaults.
///
/// This contract was originally defined within the DeFiActions contract but has been extracted here to allow
/// independent deployment and upgrades without requiring a DeFiActions redeployment.
///
access(all) contract AutoBalancers {

    /* --- EVENTS --- */

    /// Emitted when an AutoBalancer is created
    access(all) event CreatedAutoBalancer(
        lowerThreshold: UFix64,
        upperThreshold: UFix64,
        vaultType: String,
        vaultUUID: UInt64,
        uuid: UInt64,
        uniqueID: UInt64?
    )
    /// Emitted when AutoBalancer.rebalance() is called
    access(all) event Rebalanced(
        amount: UFix64,
        value: UFix64,
        unitOfAccount: String,
        isSurplus: Bool,
        vaultType: String,
        vaultUUID: UInt64,
        balancerUUID: UInt64,
        address: Address?,
        uniqueID: UInt64?
    )
    /// Emitted when an AutoBalancer fails to self-schedule a recurring rebalance
    access(all) event FailedRecurringSchedule(
        whileExecuting: UInt64,
        balancerUUID: UInt64,
        address: Address?,
        error: String,
        uniqueID: UInt64?
    )

    /// AutoBalancerSink
    ///
    /// A DeFiActions Sink enabling the deposit of funds to an underlying AutoBalancer resource. As written, this Source
    /// may be used with externally defined AutoBalancer implementations
    ///
    access(all) struct AutoBalancerSink : DeFiActions.Sink {
        /// The Type this Sink accepts
        access(self) let type: Type
        /// An authorized Capability on the underlying AutoBalancer where funds are deposited
        access(self) let autoBalancer: Capability<&AutoBalancer>
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(autoBalancer: Capability<&AutoBalancer>, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                autoBalancer.check():
                "Invalid AutoBalancer Capability Provided"
            }
            self.type = autoBalancer.borrow()!.vaultType()
            self.autoBalancer = autoBalancer
            self.uniqueID = uniqueID
        }

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.type
        }
        /// Returns an estimate of how much can be withdrawn from the depositing Vault for this Sink to reach capacity
        /// can currently only be UFix64.max or 0.0
        access(all) fun minimumCapacity(): UFix64 {
            return self.autoBalancer.check() ? UFix64.max : 0.0
        }
        /// Deposits up to the Sink's capacity from the provided Vault
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let ab = self.autoBalancer.borrow() {
                ab.deposit(from: <-from.withdraw(amount: from.balance))
            }
            return
        }
        /// Returns a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        /// each inner component in the stack.
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// AutoBalancerSource
    ///
    /// A DeFiActions Source targeting an underlying AutoBalancer resource. As written, this Source may be used with
    /// externally defined AutoBalancer implementations
    ///
    access(all) struct AutoBalancerSource : DeFiActions.Source {
        /// The Type this Source provides
        access(self) let type: Type
        /// An authorized Capability on the underlying AutoBalancer where funds are sourced
        access(self) let autoBalancer: Capability<auth(FungibleToken.Withdraw) &AutoBalancer>
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(autoBalancer: Capability<auth(FungibleToken.Withdraw) &AutoBalancer>, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                autoBalancer.check():
                "Invalid AutoBalancer Capability Provided"
            }
            self.type = autoBalancer.borrow()!.vaultType()
            self.autoBalancer = autoBalancer
            self.uniqueID = uniqueID
        }

        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.type
        }
        /// Returns an estimate of how much of the associated Vault Type can be provided by this Source
        access(all) fun minimumAvailable(): UFix64 {
            if let ab = self.autoBalancer.borrow() {
                return ab.vaultBalance()
            }
            return 0.0
        }
        /// Withdraws the lesser of maxAmount or minimumAvailable(). If none is available, an empty Vault should be
        /// returned
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if let ab = self.autoBalancer.borrow() {
                return <-ab.withdraw(
                    amount: maxAmount <= ab.vaultBalance() ? maxAmount : ab.vaultBalance()
                )
            }
            return <- DeFiActionsUtils.getEmptyVault(self.type)
        }
        /// Returns a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        /// each inner component in the stack.
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// Entitlement used by the AutoBalancer to set inner Sink and Source
    access(all) entitlement Auto
    access(all) entitlement Set
    access(all) entitlement Get
    access(all) entitlement Configure
    access(all) entitlement Schedule

    /// AutoBalancerRecurringConfig
    ///
    /// A struct containing the configuration so that a recurring rebalance of an AutoBalancer can be scheduled
    ///
    access(all) struct AutoBalancerRecurringConfig {
        /// How frequently the rebalance will be executed (in seconds)
        access(all) let interval: UInt64
        /// The priority of the rebalance
        access(all) let priority: FlowTransactionScheduler.Priority
        /// The execution effort of the rebalance
        access(all) let executionEffort: UInt64
        /// The AutoBalancer UUID that this config is assigned to
        access(all) var assignedAutoBalancer: UInt64?
        /// The force rebalance flag
        access(contract) let forceRebalance: Bool
        /// The txnFunder used to fund the rebalance - must provide FLOW and accept FLOW
        access(contract) var txnFunder: {DeFiActions.Sink, DeFiActions.Source}

        init(
            interval: UInt64,
            priority: FlowTransactionScheduler.Priority,
            executionEffort: UInt64,
            forceRebalance: Bool,
            txnFunder: {DeFiActions.Sink, DeFiActions.Source}
        ) {
            pre {
                interval > 0:
                "Invalid interval: \(interval) - must be greater than 0"
                interval < UInt64(UFix64.max) - UInt64(getCurrentBlock().timestamp):
                "Invalid interval: \(interval) - must be less than the maximum interval of \(UInt64(UFix64.max) - UInt64(getCurrentBlock().timestamp))"
                txnFunder.getSourceType() == Type<@FlowToken.Vault>():
                "Invalid txnFunder: \(txnFunder.getSourceType().identifier) - must provide FLOW but provides \(txnFunder.getSourceType().identifier)"
                txnFunder.getSinkType() == Type<@FlowToken.Vault>():
                "Invalid txnFunder: \(txnFunder.getSinkType().identifier) - must accept FLOW but accepts \(txnFunder.getSinkType().identifier)"
            }
            let schedulerConfig = FlowTransactionScheduler.getConfig()
            let minEffort = schedulerConfig.minimumExecutionEffort
            assert(executionEffort >= minEffort,
                message: "Invalid execution effort: \(executionEffort) - must be greater than or equal to the minimum execution effort of \(minEffort)")
            assert(executionEffort <= schedulerConfig.maximumIndividualEffort,
                message: "Invalid execution effort: \(executionEffort) - must be less than or equal to the maximum individual effort of \(schedulerConfig.maximumIndividualEffort)")

            self.interval = interval
            self.priority = priority
            self.executionEffort = executionEffort
            self.forceRebalance = forceRebalance
            self.txnFunder = txnFunder
            self.assignedAutoBalancer = nil
        }

        /// Sets the AutoBalancer's UUID that this config is assigned to when this AutoBalancerRecurringConfig is set
        access(contract) fun setAssignedAutoBalancer(_ uuid: UInt64) {
            pre {
                self.assignedAutoBalancer == nil || self.assignedAutoBalancer == uuid:
                "Invalid AutoBalancer UUID \(uuid): AutoBalancerConfig.assignedAutoBalancer is already set to \(self.assignedAutoBalancer!)"
            }
            self.assignedAutoBalancer = uuid
        }
    }

    /// Callback invoked every time an AutoBalancer executes (runs rebalance).
    ///
    access(all) resource interface AutoBalancerExecutionCallback {
        /// Called at the end of each rebalance run.
        /// @param balancerUUID: The AutoBalancer's UUID
        access(all) fun onExecuted(balancerUUID: UInt64)
    }

    /// AutoBalancer
    ///
    /// A resource designed to enable permissionless rebalancing of value around a wrapped Vault. An
    /// AutoBalancer can be a critical component of DeFiActions stacks by allowing for strategies to compound, repay
    /// loans or direct accumulated value to other sub-systems and/or user Vaults.
    ///
    access(all) resource AutoBalancer :
        DeFiActions.IdentifiableResource,
        FungibleToken.Receiver,
        FungibleToken.Provider,
        ViewResolver.Resolver,
        Burner.Burnable,
        FlowTransactionScheduler.TransactionHandler
    {
        /// The value in deposits & withdrawals over time denominated in oracle.unitOfAccount()
        access(self) var _valueOfDeposits: UFix64
        /// The percentage low and high thresholds defining when a rebalance executes
        /// Index 0 is low, index 1 is high
        access(self) var _rebalanceRange: [UFix64; 2]
        /// Oracle used to track the baseValue for deposits & withdrawals over time
        access(self) let _oracle: {DeFiActions.PriceOracle}
        /// The inner Vault's Type captured for the ResourceDestroyed event
        access(self) let _vaultType: Type
        /// Vault used to deposit & withdraw from made optional only so the Vault can be burned via Burner.burn() if the
        /// AutoBalancer is burned and the Vault's burnCallback() can be called in the process
        access(self) var _vault: @{FungibleToken.Vault}?
        /// An optional Sink used to deposit excess funds from the inner Vault once the converted value exceeds the
        /// rebalance range. This Sink may be used to compound yield into a position or direct excess value to an
        /// external Vault
        access(self) var _rebalanceSink: {DeFiActions.Sink}?
        /// An optional Source used to deposit excess funds to the inner Vault once the converted value is below the
        /// rebalance range
        access(self) var _rebalanceSource: {DeFiActions.Source}?
        /// Capability on this AutoBalancer instance
        access(self) var _selfCap: Capability<auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute) &AutoBalancer>?
        /// The timestamp of the last rebalance
        access(self) var _lastRebalanceTimestamp: UFix64
        /// An optional recurring config for the AutoBalancer
        access(self) var _recurringConfig: AutoBalancerRecurringConfig?
        /// ScheduledTransaction objects used to manage automated rebalances
        access(self) var _scheduledTransactions: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// Optional callback invoked every time rebalance() runs
        access(self) var _executionCallback: Capability<&{AutoBalancerExecutionCallback}>?
        /// An optional UniqueIdentifier tying this AutoBalancer to a given stack
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// Emitted when the AutoBalancer is destroyed
        access(all) event ResourceDestroyed(
            uuid: UInt64 = self.uuid,
            vaultType: String = self._vaultType.identifier,
            balance: UFix64? = self._vault?.balance,
            uniqueID: UInt64? = self.uniqueID?.id
        )

        init(
            lower: UFix64,
            upper: UFix64,
            oracle: {DeFiActions.PriceOracle},
            vaultType: Type,
            outSink: {DeFiActions.Sink}?,
            inSource: {DeFiActions.Source}?,
            recurringConfig: AutoBalancerRecurringConfig?,
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            pre {
                lower < upper && 0.01 <= lower && lower < 1.0 && 1.0 < upper && upper < 2.0:
                "Invalid rebalanceRange [lower, upper]: [\(lower), \(upper)] - thresholds must be set such that 0.01 <= lower < 1.0 and 1.0 < upper < 2.0 relative to value of deposits"
                DeFiActionsUtils.definingContractIsFungibleToken(vaultType):
                "The contract defining Vault \(vaultType.identifier) does not conform to FungibleToken contract interface"
                recurringConfig?.assignedAutoBalancer == nil || recurringConfig?.assignedAutoBalancer == self.uuid:
                "Invalid recurringConfig: \(recurringConfig!.assignedAutoBalancer!) - must be assigned to this AutoBalancer"
            }
            assert(oracle.price(ofToken: vaultType) != nil,
                message: "Provided Oracle \(oracle.getType().identifier) could not provide a price for vault \(vaultType.identifier)")

            self._valueOfDeposits = 0.0
            self._rebalanceRange = [lower, upper]
            self._oracle = oracle
            self._vault <- DeFiActionsUtils.getEmptyVault(vaultType)
            self._vaultType = vaultType
            self._rebalanceSink = outSink
            self._rebalanceSource = inSource
            self._selfCap = nil
            self._lastRebalanceTimestamp = getCurrentBlock().timestamp
            self._recurringConfig = recurringConfig
            self._recurringConfig?.setAssignedAutoBalancer(self.uuid)
            self._scheduledTransactions <- {}
            self._executionCallback = nil
            self.uniqueID = uniqueID

            emit CreatedAutoBalancer(
                lowerThreshold: lower,
                upperThreshold: upper,
                vaultType: vaultType.identifier,
                vaultUUID: self._borrowVault().uuid,
                uuid: self.uuid,
                uniqueID: self.id()
            )
        }

        /* Core AutoBalancer Functionality */

        /// Returns the balance of the inner Vault
        ///
        /// @return the current balance of the inner Vault
        ///
        access(all) view fun vaultBalance(): UFix64 {
            return self._borrowVault().balance
        }
        /// Returns the Type of the inner Vault
        ///
        /// @return the Type of the inner Vault
        ///
        access(all) view fun vaultType(): Type {
            return self._borrowVault().getType()
        }
        /// Returns the low and high rebalance thresholds as a fixed length UFix64 containing [low, high]
        ///
        /// @return a sorted fixed-length array containing the relative lower and upper thresholds conditioning
        ///     rebalance execution
        ///
        access(all) view fun rebalanceThresholds(): [UFix64; 2] {
            return self._rebalanceRange
        }
        /// Returns the value of all accounted deposits/withdraws as they have occurred denominated in unitOfAccount.
        /// The returned value is the value as tracked historically, not necessarily the current value of the inner
        /// Vault's balance.
        ///
        /// @return the historical value of deposits
        ///
        access(all) view fun valueOfDeposits(): UFix64 {
            return self._valueOfDeposits
        }
        /// Returns the token Type serving as the price basis of this AutoBalancer
        ///
        /// @return the price denomination of value of the underlying vault as returned from the inner PriceOracle
        ///
        access(all) view fun unitOfAccount(): Type {
            return self._oracle.unitOfAccount()
        }
        /// Returns the current value of the inner Vault's balance. If a price is not available from the AutoBalancer's
        /// PriceOracle, `nil` is returned
        ///
        /// @return the current value of the inner's Vault's balance denominated in unitOfAccount() if a price is
        ///     available, `nil` otherwise
        ///
        access(all) fun currentValue(): UFix64? {
            if let price = self._oracle.price(ofToken: self.vaultType()) {
                return price * self._borrowVault().balance
            }
            return nil
        }
        /// Returns a ComponentInfo struct containing information about this AutoBalancer and its inner DFA components
        ///
        /// @return a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        ///     each inner component in the stack.
        ///
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            // get the inner components
            let oracle = self._borrowOracle()
            let inner = [oracle.getComponentInfo()]

            // get the info for the optional inner components if they exist
            let maybeSink = self._borrowSink()
            let maybeSource = self._borrowSource()
            if let sink = maybeSink {
                inner.append(sink.getComponentInfo())
            }
            if let source = maybeSource {
                inner.append(source.getComponentInfo())
            }

            // create the ComponentInfo for the AutoBalancer and insert it at the beginning of the list
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: inner
            )
        }
        /// Convenience method issuing a Sink allowing for deposits to this AutoBalancer. If the AutoBalancer's
        /// Capability on itself is not set or is invalid, `nil` is returned.
        ///
        /// @return a Sink routing deposits to this AutoBalancer
        ///
        access(all) fun createBalancerSink(): {DeFiActions.Sink}? {
            if self._selfCap == nil || !self._selfCap!.check() {
                return nil
            }
            return AutoBalancerSink(autoBalancer: self._selfCap!, uniqueID: self.uniqueID)
        }
        /// Convenience method issuing a Source enabling withdrawals from this AutoBalancer. If the AutoBalancer's
        /// Capability on itself is not set or is invalid, `nil` is returned.
        ///
        /// @return a Source routing withdrawals from this AutoBalancer
        ///
        access(Get) fun createBalancerSource(): {DeFiActions.Source}? {
            if self._selfCap == nil || !self._selfCap!.check() {
                return nil
            }
            return AutoBalancerSource(autoBalancer: self._selfCap!, uniqueID: self.uniqueID)
        }
        /// A setter enabling an AutoBalancer to set a Sink to which overflow value should be deposited
        ///
        /// @param sink: The optional Sink DeFiActions connector from which funds are sourced when this AutoBalancer
        ///     current value rises above the upper threshold relative to its valueOfDeposits(). If `nil`, overflown
        ///     value will not rebalance
        ///
        access(Set) fun setSink(_ sink: {DeFiActions.Sink}?, updateSinkID: Bool) {
            if sink != nil && updateSinkID {
                let toUpdate = &sink! as auth(DeFiActions.Extend) &{DeFiActions.IdentifiableStruct}
                let toAlign = &self as auth(DeFiActions.Identify) &{DeFiActions.IdentifiableResource}
                DeFiActions.alignID(toUpdate: toUpdate, with: toAlign)
            }
            self._rebalanceSink = sink
        }
        /// A setter enabling an AutoBalancer to set a Source from which underflow value should be withdrawn
        ///
        /// @param source: The optional Source DeFiActions connector from which funds are sourced when this AutoBalancer
        ///     current value falls below the lower threshold relative to its valueOfDeposits(). If `nil`, underflown
        ///     value will not rebalance
        ///
        access(Set) fun setSource(_ source: {DeFiActions.Source}?, updateSourceID: Bool) {
            if source != nil && updateSourceID {
                let toUpdate = &source! as auth(DeFiActions.Extend) &{DeFiActions.IdentifiableStruct}
                let toAlign = &self as auth(DeFiActions.Identify) &{DeFiActions.IdentifiableResource}
                DeFiActions.alignID(toUpdate: toUpdate, with: toAlign)
            }
            self._rebalanceSource = source
        }
        /// Enables the setting of a Capability on the AutoBalancer for the distribution of Sinks & Sources targeting
        /// the AutoBalancer instance. Due to the mechanisms of Capabilities, this must be done after the AutoBalancer
        /// has been saved to account storage and an authorized Capability has been issued.
        access(Set) fun setSelfCapability(_ cap: Capability<auth(FungibleToken.Withdraw, FlowTransactionScheduler.Execute) &AutoBalancer>) {
            pre {
                self._selfCap == nil || self._selfCap!.check() != true:
                "Internal AutoBalancer Capability has been set and is still valid - cannot be re-assigned"
                cap.check(): "Invalid AutoBalancer Capability provided"
                self.getType() == cap.borrow()!.getType() && self.uuid == cap.borrow()!.uuid:
                "Provided Capability does not target this AutoBalancer of type \(self.getType().identifier) with UUID \(self.uuid) - provided Capability for AutoBalancer of type \(cap.borrow()!.getType().identifier) with UUID \(cap.borrow()!.uuid)"
            }
            self._selfCap = cap
        }
        /// Sets the rebalance range of this AutoBalancer
        ///
        /// @param range: a sorted array containing lower and upper thresholds that condition rebalance execution. The
        ///     thresholds must be values such that 0.01 <= range[0] < 1.0 && 1.0 < range[1] < 2.0
        ///
        access(Set) fun setRebalanceRange(_ range: [UFix64; 2]) {
            pre {
                range[0] < range[1] && 0.01 <= range[0] && range[0] < 1.0 && 1.0 < range[1] && range[1] < 2.0:
                "Invalid rebalanceRange [lower, upper]: [\(range[0]), \(range[1])] - thresholds must be set such that 0.01 <= range[0] < 1.0 and 1.0 < range[1] < 2.0 relative to value of deposits"
            }
            self._rebalanceRange = range
        }
        /// Sets the optional callback invoked every time this AutoBalancer runs rebalance.
        /// Pass nil to clear the callback.
        access(Set) fun setExecutionCallback(_ cap: Capability<&{AutoBalancerExecutionCallback}>?) {
            self._executionCallback = cap
        }
        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
        /// Returns the timestamp of the last rebalance
        ///
        /// @return the timestamp of the last rebalance
        ///
        access(all) view fun getLastRebalanceTimestamp(): UFix64 {
            return self._lastRebalanceTimestamp
        }
        /// Allows for external parties to call on the AutoBalancer and execute a rebalance according to it's rebalance
        /// parameters. This method must be called by external party regularly in order for rebalancing to occur.
        ///
        /// @param force: if false, rebalance will occur only when beyond upper or lower thresholds; if true, rebalance
        ///     will execute as long as a price is available via the oracle and the current value is non-zero
        ///
        access(Auto) fun rebalance(force: Bool) {
            self._lastRebalanceTimestamp = getCurrentBlock().timestamp

            let currentPrice = self._oracle.price(ofToken: self._vaultType)
            if currentPrice == nil {
                return // no price available -> do nothing
            }
            let currentValue = self.currentValue()!
            // calculate the difference between the current value and the historical value of deposits
            var valueDiff: UFix64 = currentValue < self._valueOfDeposits ? self._valueOfDeposits - currentValue : currentValue - self._valueOfDeposits
            // if deficit detected, choose lower threshold, otherwise choose upper threshold
            let isDeficit = currentValue < self._valueOfDeposits
            let threshold = isDeficit ? (1.0 - self._rebalanceRange[0]) : (self._rebalanceRange[1] - 1.0)

            if currentPrice == 0.0 || valueDiff == 0.0 || ((valueDiff / self._valueOfDeposits) < threshold && !force) {
                // division by zero, no difference, or difference does not exceed rebalance ratio & not forced -> no-op
                return
            }

            let vault = self._borrowVault()
            var amount = self.toUFix64(UFix128(valueDiff) / UFix128(currentPrice!))
            var executed = false
            let maybeRebalanceSource = &self._rebalanceSource as auth(FungibleToken.Withdraw) &{DeFiActions.Source}?
            let maybeRebalanceSink = &self._rebalanceSink as &{DeFiActions.Sink}?
            if isDeficit && maybeRebalanceSource != nil {
                // rebalance back up to baseline sourcing funds from _rebalanceSource
                let depositVault <- maybeRebalanceSource!.withdrawAvailable(maxAmount: amount)
                amount = depositVault.balance // update the rebalanced amount based on actual deposited amount
                vault.deposit(from: <-depositVault)
                executed = true
            } else if !isDeficit && maybeRebalanceSink != nil {
                // rebalance back down to baseline depositing excess to _rebalanceSink
                if amount > vault.balance {
                    amount = vault.balance // protect underflow
                }
                let surplus <- vault.withdraw(amount: amount)
                maybeRebalanceSink!.depositCapacity(from: &surplus as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                executed = true
                if surplus.balance == 0.0 {
                    Burner.burn(<-surplus) // could destroy
                } else {
                    amount = amount - surplus.balance // update the rebalanced amount
                    valueDiff = valueDiff - (surplus.balance * currentPrice!) // update the value difference
                    vault.deposit(from: <-surplus) // deposit any excess not taken by the Sink
                }
            }
            // emit event only if rebalance was executed
            if executed {
                emit Rebalanced(
                    amount: amount,
                    value: valueDiff,
                    unitOfAccount: self.unitOfAccount().identifier,
                    isSurplus: !isDeficit,
                    vaultType: self.vaultType().identifier,
                    vaultUUID: self._borrowVault().uuid,
                    balancerUUID: self.uuid,
                    address: self.owner?.address,
                    uniqueID: self.id()
                )
            }
        }

        /* FlowTransactionScheduler.TransactionHandler conformance & related logic */

        /// Intended to be used by the FlowTransactionScheduler to execute the rebalance.
        ///
        /// NOTE: if transactions are scheduled externally, they will not automatically schedule the next execution even
        /// if the AutoBalancer is configured as recurring. This enables external parties to schedule transactions
        /// independently as either one-offs or manage recurring schedules by their own means.
        ///
        /// @param id: The id of the scheduled transaction
        /// @param data: The data that was passed when the transaction was originally scheduled
        ///
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            // execute as declared, otherwise execute as currently configured, otherwise default to false
            let dataDict = data as? {String: AnyStruct} ?? {}
            let force = dataDict["force"] as? Bool ?? self._recurringConfig?.forceRebalance as? Bool ?? false

            self.rebalance(force: force)

            // If configured as recurring, schedule the next execution only if this is an internally-managed
            // scheduled transaction. Externally-scheduled transactions are treated as "fire once" to support
            // external scheduling logic that manages its own recurring behavior.
            if self._recurringConfig != nil {
                let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
                if isInternallyManaged {
                    if let err = self.scheduleNextRebalance(whileExecuting: id) {
                        emit FailedRecurringSchedule(
                            whileExecuting: id,
                            balancerUUID: self.uuid,
                            address: self.owner?.address,
                            error: err,
                            uniqueID: self.uniqueID?.id
                        )
                    }
                }
            }
            if let cap = self._executionCallback {
                if cap.check() {
                    cap.borrow()!.onExecuted(balancerUUID: self.uniqueID?.id ?? 0)
                }
            }
            // clean up internally-managed historical scheduled transactions
            self._cleanupScheduledTransactions()
        }

        /// Schedules the next execution of the rebalance if the AutoBalancer is configured as such and there is not
        /// already a scheduled transaction within the desired interval. This method is written to fail as gracefully as
        /// possible, reporting any failures to schedule the next execution to the as an event. This allows
        /// `executeTransaction` to continue execution even if the next execution cannot be scheduled while still
        /// informing of the failure via `FailedRecurringSchedule` event.
        ///
        /// @param whileExecuting: The ID of the transaction that is currently executing or nil if called externally
        ///
        /// @return String?: The error message, or nil if the next execution was scheduled
        ///
        access(Schedule) fun scheduleNextRebalance(whileExecuting: UInt64?): String? {
            // perform pre-flight checks before estimating the transaction fees
            if self._recurringConfig == nil {
                return "MISSING_RECURRING_CONFIG"
            } else if self._selfCap?.check() != true {
                return "INVALID_SELF_CAPABILITY"
            }
            let config = self._recurringConfig!
            // get the next execution timestamp
            var timestamp = self.calculateNextExecutionTimestampAsConfigured()!
            // fallback in event there was an issue with assigning the last rebalance timestamp or last rebalance was
            // executed long ago - ensure timestamp is in the future
            let nextPossibleTimestamp = getCurrentBlock().timestamp.saturatingAdd(1.0)
            if timestamp < nextPossibleTimestamp {
                timestamp = nextPossibleTimestamp
            }
            if timestamp == UFix64.max {
                return "INTERVAL_OVERFLOW"
            }

            // check for other scheduled transactions within the desired interval
            for id in self._scheduledTransactions.keys {
                if id == whileExecuting {
                    continue
                }
                let scheduledTxn = self.borrowScheduledTransaction(id: id)!
                if scheduledTxn.status() == FlowTransactionScheduler.Status.Scheduled {
                    // found another scheduled transaction within the configured interval
                    if scheduledTxn.timestamp <= timestamp {
                        return nil
                    }
                }
            }

            // estimate the transaction fees
            let estimate = FlowTransactionScheduler.estimate(
                data: config.forceRebalance,
                timestamp: timestamp,
                priority: config.priority,
                executionEffort: config.executionEffort
            )
            // post-estimate check if the estimate is valid & that the funder has enough funds of the correct type
            // NOTE: low priority estimates always receive non-nil errors but are still valid if fee is also non-nil
            if config.txnFunder.getSourceType() != Type<@FlowToken.Vault>() {
                return "INVALID_FEE_TYPE"
            }
            if estimate.flowFee == nil {
                return estimate.error ?? "ESTIMATE_FAILED"
            }
            if config.txnFunder.minimumAvailable() < (estimate.flowFee! * 1.05) {
                // Check with 5% margin buffer to match withdrawal
                return "INSUFFICIENT_FEES_AVAILABLE"
            }

            // withdraw the fees from the funder with a margin buffer (fee estimation can vary slightly)
            // Add 5% margin to handle estimation variance
            let feeWithMargin = estimate.flowFee! * 1.05
            let fees <- config.txnFunder.withdrawAvailable(maxAmount: feeWithMargin) as! @FlowToken.Vault
            if fees.balance < estimate.flowFee! {
                config.txnFunder.depositCapacity(from: &fees as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                destroy fees
                return "INSUFFICIENT_FEES_PROVIDED"
            } else {
                // all checks passed - schedule the transaction & capture the scheduled transaction
                let txn <- FlowTransactionScheduler.schedule(
                        handlerCap: self._selfCap!,
                        data: { "force": config.forceRebalance },
                        timestamp: timestamp,
                        priority: config.priority,
                        executionEffort: config.executionEffort,
                        fees: <-fees
                    )
                let txnID = txn.id
                self._scheduledTransactions[txnID] <-! txn
                return nil
            }
        }
        /// Returns the IDs of the scheduled transactions.
        /// NOTE: this does not include externally scheduled transactions
        ///
        /// @return [UInt64]: The IDs of the scheduled transactions
        ///
        access(all) view fun getScheduledTransactionIDs(): [UInt64] {
            return self._scheduledTransactions.keys
        }
        /// Borrows a reference to the internally-managed scheduled transaction or nil if not found.
        /// NOTE: this does not include externally scheduled transactions
        ///
        /// @param id: The ID of the scheduled transaction
        ///
        /// @return &FlowTransactionScheduler.ScheduledTransaction?: The reference to the scheduled transaction, or nil
        /// if the scheduled transaction is not found
        ///
        access(all) view fun borrowScheduledTransaction(id: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
            return &self._scheduledTransactions[id]
        }
        /// Calculates the next execution timestamp for a recurring rebalance if the AutoBalancer is configured as such.
        /// Returns nil if unconfigured for recurring rebalancing.
        ///
        /// @return UFix64?: The next execution timestamp, or nil if a recurring rebalance is not configured
        ///
        access(all) view fun calculateNextExecutionTimestampAsConfigured(): UFix64? {
            if let config = self._recurringConfig {
                return self._lastRebalanceTimestamp.saturatingAdd(UFix64(config.interval))
            }
            return nil
        }
        /// Returns the recurring config for the AutoBalancer
        ///
        /// @return AutoBalancerRecurringConfig?: The recurring config, or nil if recurring rebalancing is not configured
        ///
        access(all) view fun getRecurringConfig(): AutoBalancerRecurringConfig? {
            return self._recurringConfig
        }
        /// Sets the recurring config for the AutoBalancer
        ///
        /// @param config: The recurring config to set, or nil to disable recurring rebalancing
        ///
        access(Configure) fun setRecurringConfig(_ config: AutoBalancerRecurringConfig?) {
            pre {
                config?.assignedAutoBalancer == nil || config?.assignedAutoBalancer == self.uuid:
                "Invalid recurring config - must be assigned to this AutoBalancer"
            }
            config?.setAssignedAutoBalancer(self.uuid)
            self._recurringConfig = config
        }
        /// Cancels a scheduled transaction returning nil if a scheduled transaction is not found. Refunds are deposited
        /// to the configured txn fee funder primarily, returning any excess to the caller.
        ///
        /// @param id: The ID of the scheduled transaction to cancel
        ///
        /// @return @FlowToken.Vault?: The refunded vault, or nil if a scheduled transaction is not found
        ///
        access(FlowTransactionScheduler.Cancel) fun cancelScheduledTransaction(id: UInt64): @FlowToken.Vault? {
            if self._scheduledTransactions[id] == nil {
                return nil
            }
            let txn <- self._scheduledTransactions.remove(key: id)
            let refund <- FlowTransactionScheduler.cancel(scheduledTx: <-txn!)
            if let config = self._recurringConfig {
                config.txnFunder.depositCapacity(from: &refund as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            }
            return <- refund
        }
        /// Cleans up the internally-managed scheduled transactions
        access(self) fun _cleanupScheduledTransactions() {
            // limit to prevent running into computation limits
            let limit = 50
            var iter = 0
            // iterate over the scheduled transactions and remove those that are not scheduled
            for id in self._scheduledTransactions.keys {
                iter = iter + 1
                if iter > limit {
                    break
                }
                let ref = &self._scheduledTransactions[id] as &FlowTransactionScheduler.ScheduledTransaction?
                if ref?.status() != FlowTransactionScheduler.Status.Scheduled {
                    let txn <- self._scheduledTransactions.remove(key: id)
                    destroy txn
                }
            }
        }

        /* ViewResolver.Resolver conformance */

        /// Passthrough to inner Vault's view Types adding also the AutoBalancerRecurringConfig type
        access(all) view fun getViews(): [Type] {
            return [Type<AutoBalancerRecurringConfig>()].concat(self._borrowVault().getViews())
        }
        /// Passthrough to inner Vault's view resolution serving also the AutoBalancerRecurringConfig type
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            if view == Type<AutoBalancerRecurringConfig>() {
                return self._recurringConfig
            } else {
                return self._borrowVault().resolveView(view)
            }
        }

        /* FungibleToken.Receiver & .Provider conformance */

        /// Only the nested Vault type is supported by this AutoBalancer for deposits & withdrawal for the sake of
        /// single asset accounting
        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return { self.vaultType(): true }
        }
        /// True if the provided Type is the nested Vault Type, false otherwise
        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return self.getSupportedVaultTypes()[type] == true
        }
        /// Passthrough to the inner Vault's isAvailableToWithdraw() method
        access(all) view fun isAvailableToWithdraw(amount: UFix64): Bool {
            return self._borrowVault().isAvailableToWithdraw(amount: amount)
        }
        /// Deposits the provided Vault to the nested Vault if it is of the same Type, reverting otherwise. In the
        /// process, the current value of the deposited amount (denominated in unitOfAccount) increments the
        /// AutoBalancer's baseValue. If a price is not available via the internal PriceOracle, the operation reverts.
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                from.getType() == self.vaultType():
                "Invalid Vault type \(from.getType().identifier) deposited - this AutoBalancer only accepts \(self.vaultType().identifier)"
            }
            // assess value & complete deposit - if none available, revert
            let price = self._oracle.price(ofToken: from.getType())
                ?? panic("No price available for \(from.getType().identifier) to assess value of deposit")
            self._valueOfDeposits = self._valueOfDeposits + (from.balance * price)
            self._borrowVault().deposit(from: <-from)
        }
        /// Returns the requested amount of the nested Vault type, reducing the baseValue by the current value
        /// (denominated in unitOfAccount) of the token amount. The AutoBalancer's valueOfDeposits is decremented
        /// in proportion to the amount withdrawn relative to the inner Vault's balance
        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
            pre {
                amount <= self.vaultBalance(): "Withdraw amount \(amount) exceeds current vault balance \(self.vaultBalance())"
            }
            if amount == 0.0 {
                return <- self._borrowVault().createEmptyVault()
            }

            // adjust historical value of deposits proportionate to the amount withdrawn & return withdrawn vault
            let amount128 = UFix128(amount)
            let vaultBalance128 = UFix128(self.vaultBalance())
            let proportion: UFix64 = 1.0 - self.toUFix64(amount128 / vaultBalance128)
            let newValue = self._valueOfDeposits * proportion
            self._valueOfDeposits = newValue
            return <- self._borrowVault().withdraw(amount: amount)
        }

        /* Burnable.Burner conformance */

        /// Executed in Burner.burn(). Passes along the inner vault to be burned, executing the inner Vault's
        /// burnCallback() logic
        access(contract) fun burnCallback() {
            let vault <- self._vault <- nil
            Burner.burn(<-vault) // executes the inner Vault's burnCallback()
        }

        /* Internal */

        /// Returns a reference to the inner Vault
        access(self) view fun _borrowVault(): auth(FungibleToken.Withdraw) &{FungibleToken.Vault} {
            return (&self._vault)!
        }
        /// Returns a reference to the inner Vault
        access(self) view fun _borrowOracle(): &{DeFiActions.PriceOracle} {
            return &self._oracle
        }
        /// Returns a reference to the inner Vault
        access(self) view fun _borrowSink(): &{DeFiActions.Sink}? {
            return &self._rebalanceSink
        }
        /// Returns a reference to the inner Source
        access(self) view fun _borrowSource(): auth(FungibleToken.Withdraw) &{DeFiActions.Source}? {
            return &self._rebalanceSource
        }
        /// Converts a UFix128 to a UFix64, rounding up if the remainder is greater than or equal to 0.5
        access(all) view fun toUFix64(_ value: UFix128): UFix64 {
            let truncated = UFix64(value)
            let truncatedAs128 = UFix128(truncated)
            let remainder = value - truncatedAs128
            let ufix64Step: UFix128 = 0.00000001
            let ufix64HalfStep: UFix128 = ufix64Step / 2.0

            if remainder == 0.0 {
                return truncated
            }

            view fun roundUp(_ base: UFix64): UFix64 {
                let increment = 0.00000001
                return base >= UFix64.max - increment ? UFix64.max : base + increment
            }

            return remainder >= ufix64HalfStep ? roundUp(truncated) : truncated
        }
    }

    /* --- PUBLIC METHODS --- */

    /// Returns an AutoBalancer wrapping the provided Vault.
    ///
    /// @param oracle: The oracle used to query deposited & withdrawn value and to determine if a rebalance should execute
    /// @param vault: The Vault wrapped by the AutoBalancer
    /// @param rebalanceRange: The percentage range from the AutoBalancer's base value at which a rebalance is executed
    /// @param outSink: An optional DeFiActions Sink to which excess value is directed when rebalancing
    /// @param inSource: An optional DeFiActions Source from which value is withdrawn to the inner vault when rebalancing
    /// @param uniqueID: An optional DeFiActions UniqueIdentifier used for identifying rebalance events
    ///
    access(all) fun createAutoBalancer(
        oracle: {DeFiActions.PriceOracle},
        vaultType: Type,
        lowerThreshold: UFix64,
        upperThreshold: UFix64,
        rebalanceSink: {DeFiActions.Sink}?,
        rebalanceSource: {DeFiActions.Source}?,
        recurringConfig: AutoBalancerRecurringConfig?,
        uniqueID: DeFiActions.UniqueIdentifier?
    ): @AutoBalancer {
        let ab <- create AutoBalancer(
            lower: lowerThreshold,
            upper: upperThreshold,
            oracle: oracle,
            vaultType: vaultType,
            outSink: rebalanceSink,
            inSource: rebalanceSource,
            recurringConfig: recurringConfig,
            uniqueID: uniqueID
        )
        return <- ab
    }

    /// Derives the path identifier for an AutoBalancer for a given vault type
    access(all) view fun deriveAutoBalancerPathIdentifier(vaultType: Type): String? {
        if !vaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()) {
            return nil
        }
        return "AutoBalancer_\(vaultType.identifier)"
    }

    init() {}
}
