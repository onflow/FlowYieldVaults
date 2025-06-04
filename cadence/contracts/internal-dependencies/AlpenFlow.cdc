import "FungibleToken"
import "ViewResolver"
import "Burner"
import "MetadataViews"
import "FungibleTokenMetadataViews"
import "DFB"
// CHANGE: Import FlowToken to use the real FLOW token implementation
// This replaces our test FlowVault with the actual Flow token
import "FlowToken"

access(all) contract AlpenFlow: FungibleToken {

    access(all) entitlement Withdraw

    // REMOVED: FlowVault resource implementation (previously lines 12-56)
    // The FlowVault resource has been removed to prevent type conflicts
    // with the real FlowToken.Vault when integrating with Tidal contracts.
    // All references to FlowVault will now use FlowToken.Vault instead.

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

    // A structure used internally to track a position's balance for a particular token.
    access(all) struct InternalBalance {
        access(all) var direction: BalanceDirection

        // Interally, position balances are tracked using a "scaled balance". The "scaled balance" is the
        // actual balance divided by the current interest index for the associated token. This means we don't
        // need to update the balance of a position as time passes, even as interest rates change. We only need
        // to update the scaled balance when the user deposits or withdraws funds. The interest index
        // is a number relatively close to 1.0, so the scaled balance will be roughly of the same order
        // of magnitude as the actual balance (thus we can use UFix64 for the scaled balance).
        access(all) var scaledBalance: UFix64

        init() {
            self.direction = BalanceDirection.Credit
            self.scaledBalance = 0.0
        }

        access(all) fun recordDeposit(amount: UFix64, tokenState: auth(EImplementation) &TokenState) {
            if self.direction == BalanceDirection.Credit {
                // Depositing into a credit position just increases the balance.

                // To maximize precision, we could convert the scaled balance to a true balance, add the
                // deposit amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small deposits (fractions of a cent), so we save computational
                // cycles by just scaling the deposit amount and adding it directly to the scaled balance.
                let scaledDeposit = AlpenFlow.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.creditInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledDeposit

                // Increase the total credit balance for the token
                tokenState.updateCreditBalance(amount: Fix64(amount))
            } else {
                // When depositing into a debit position, we first need to compute the true balance to see
                // if this deposit will flip the position from debit to credit.
                let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.debitInterestIndex)

                if trueBalance > amount {
                    // The deposit isn't big enough to clear the debt, so we just decrement the debt.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the total debit balance for the token
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The deposit is enough to clear the debt, so we switch to a credit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Credit
                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Increase the credit balance AND decrease the debit balance
                    tokenState.updateCreditBalance(amount: Fix64(updatedBalance))
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(trueBalance))
                }
            }
        }

        access(all) fun recordWithdrawal(amount: UFix64, tokenState: &TokenState) {
            if self.direction == BalanceDirection.Debit {
                // Withdrawing from a debit position just increases the debt amount.

                // To maximize precision, we could convert the scaled balance to a true balance, subtract the
                // withdrawal amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small withdrawals (fractions of a cent), so we save computational
                // cycles by just scaling the withdrawal amount and subtracting it directly from the scaled balance.
                let scaledWithdrawal = AlpenFlow.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.debitInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledWithdrawal

                // Increase the total debit balance for the token
                tokenState.updateDebitBalance(amount: Fix64(amount))
            } else {
                // When withdrawing from a credit position, we first need to compute the true balance to see
                // if this withdrawal will flip the position from credit to debit.
                let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.creditInterestIndex)

                if trueBalance >= amount {
                    // The withdrawal isn't big enough to push the position into debt, so we just decrement the
                    // credit balance.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Decrease the total credit balance for the token
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The withdrawal is enough to push the position into debt, so we switch to a debit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Debit
                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the credit balance AND increase the debit balance
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(trueBalance))
                    tokenState.updateDebitBalance(amount: Fix64(updatedBalance))
                }
            }
        }
    }

    access(all) entitlement mapping ImplementationUpdates {
        EImplementation -> Mutate
    }

    access(all) struct InternalPosition {
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}

        init() {
            self.balances = {}
        }
    }

    access(all) struct interface InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64
        {
            post {
                result <= 1.0: "Interest rate can't exceed 100%"
            }
        }
    }

    access(all) struct SimpleInterestCurve: InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64 {
            return 0.0
        }
    }

    // A multiplication function for interest calcuations. It assumes that both values are very close to 1
    // and represent fixed point numbers with 16 decimal places of precision.
    access(all) fun interestMul(_ a: UInt64, _ b: UInt64): UInt64 {
        let aScaled = a / 100000000
        let bScaled = b / 100000000

        return aScaled * bScaled
    }

    // Converts a yearly interest rate (as a UFix64) to a per-second multiplication factor
    // (stored in a UInt64 as a fixed point number with 16 decimal places). The input to this function will be
    // just the relative interest rate (e.g. 0.05 for 5% interest), but the result will be
    // the per-second multiplier (e.g. 1.000000000001).
    access(all) fun perSecondInterestRate(yearlyRate: UFix64): UInt64 {
        // Covert the yearly rate to an integer maintaning the 10^8 multiplier of UFix64.
        // We would need to multiply by an additional 10^8 to match the promised multiplier of
        // 10^16. HOWEVER, since we are about to divide by 31536000, we can save multiply a factor
        // 1000 smaller, and then divide by 31536.
        let yearlyScaledValue = UInt64.fromBigEndianBytes(yearlyRate.toBigEndianBytes())! * 100000
        let perSecondScaledValue = (yearlyScaledValue / 31536) + 10000000000000000

        return perSecondScaledValue
    }

    // Updates an interest index to reflect the passage of time. The result is:
    //   newIndex = oldIndex * perSecondRate^seconds
    access(all) fun compoundInterestIndex(oldIndex: UInt64, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt64 {
        var result = oldIndex
        var current = perSecondRate
        var secondsCounter = UInt64(elapsedSeconds)

        while secondsCounter > 0 {
            if secondsCounter & 1 == 1 {
                result = AlpenFlow.interestMul(result, current)
            }
            current = AlpenFlow.interestMul(current, current)
            secondsCounter = secondsCounter >> 1
        }

        return result
    }

    access(all) fun scaledBalanceToTrueBalance(scaledBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving and
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return scaledBalance * indexMultiplier
    }

    access(all) fun trueBalanceToScaledBalance(trueBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving and
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return trueBalance / indexMultiplier
    }

    access(all) struct TokenState {
        access(all) var lastUpdate: UFix64
        access(all) var totalCreditBalance: UFix64
        access(all) var totalDebitBalance: UFix64
        access(all) var creditInterestIndex: UInt64
        access(all) var debitInterestIndex: UInt64
        access(all) var currentCreditRate: UInt64
        access(all) var currentDebitRate: UInt64
        access(all) var interestCurve: {InterestCurve}

        access(all) fun updateCreditBalance(amount: Fix64) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalCreditBalance) + amount
            self.totalCreditBalance = UFix64(adjustedBalance)
        }

        access(all) fun updateDebitBalance(amount: Fix64) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalDebitBalance) + amount
            self.totalDebitBalance = UFix64(adjustedBalance)
        }

        access(all) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta = currentTime - self.lastUpdate
            self.creditInterestIndex = AlpenFlow.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
            self.debitInterestIndex = AlpenFlow.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
            self.lastUpdate = currentTime
        }

        access(all) fun updateInterestRates() {
            // If there's no credit balance, we can't calculate a meaningful credit rate
            // so we'll just set both rates to zero and return early
            if self.totalCreditBalance <= 0.0 {
                self.currentCreditRate = 10000000000000000  // 1.0 in fixed point (no interest)
                self.currentDebitRate = 10000000000000000   // 1.0 in fixed point (no interest)
                return
            }

            let debitRate = self.interestCurve.interestRate(creditBalance: self.totalCreditBalance, debitBalance: self.totalDebitBalance)
            let debitIncome = self.totalDebitBalance * (1.0 + debitRate)
            
                         // Calculate insurance amount (0.1% of credit balance)
             let insuranceAmount = self.totalCreditBalance * 0.001
            
            // Calculate credit rate, ensuring we don't have underflows
            var creditRate: UFix64 = 0.0
            if debitIncome >= insuranceAmount {
                creditRate = ((debitIncome - insuranceAmount) / self.totalCreditBalance) - 1.0
            } else {
                // If debit income doesn't cover insurance, we have a negative credit rate
                // but since we can't represent negative rates in our model, we'll use 0.0
                creditRate = 0.0
            }
            
            self.currentCreditRate = AlpenFlow.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = AlpenFlow.perSecondInterestRate(yearlyRate: debitRate)
        }

        init(interestCurve: {InterestCurve}) {
            self.lastUpdate = 0.0
            self.totalCreditBalance = 0.0
            self.totalDebitBalance = 0.0
            self.creditInterestIndex = 10000000000000000
            self.debitInterestIndex = 10000000000000000
            self.currentCreditRate = 10000000000000000
            self.currentDebitRate = 10000000000000000
            self.interestCurve = interestCurve
        }
    }

    access(all) resource Pool {
        // A simple version number that is incremented whenever one or more interest indices
        // are updated. This is used to detect when the interest indices need to be updated in
        // InternalPositions.
        access(EImplementation) var version: UInt64

        // Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}

        // Individual user positions
        access(self) var positions: {UInt64: InternalPosition}

        // The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}

        // Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64

        // The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        // The exchange rate between the default token and each other token supported by the pool.
        // Multiplying a quantity of the specified token by the amount stored in this dictionary
        // will provide the value of that quantity of tokens in terms of the default token.
        access(self) var exchangeRates: {Type: UFix64}

        // The liquidation threshold for each token.
        access(self) var liquidationThresholds: {Type: UFix64}

        init(defaultToken: Type, defaultTokenThreshold: UFix64) {
            self.version = 0
            self.globalLedger = {defaultToken: TokenState(interestCurve: SimpleInterestCurve())}
            self.positions = {}
            self.reserves <- {}
            self.defaultToken = defaultToken
            self.exchangeRates = {defaultToken: 1.0}
            self.liquidationThresholds = {defaultToken: defaultTokenThreshold}
            self.nextPositionID = 0

            // CHANGE: Don't create vault here - let the caller provide initial reserves
            // The pool starts with empty reserves map
            // Vaults will be added when tokens are first deposited
        }

        access(EPosition) fun deposit(pid: UInt64, funds: @{FungibleToken.Vault}) {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[funds.getType()] != nil: "Invalid token type"
                funds.balance > 0.0: "Deposit amount must be positive"
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = funds.getType()
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            tokenState.updateInterestIndices()

            // CHANGE: Create vault if it doesn't exist yet
            if self.reserves[type] == nil {
                self.reserves[type] <-! funds.createEmptyVault()
            }
            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the deposit in the position's balance
            position.balances[type]!.recordDeposit(amount: funds.balance, tokenState: tokenState)

            // Update the internal interest rate to reflect the new credit balance
            tokenState.updateInterestRates()

            // Add the money to the reserves
            reserveVault.deposit(from: <-funds)
        }

        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
                amount > 0.0: "Withdrawal amount must be positive"
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            tokenState.updateInterestIndices()

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            position.balances[type]!.recordWithdrawal(amount: amount, tokenState: tokenState)

            // Ensure that this withdrawal doesn't cause the position to be overdrawn.
            assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")

            // Update the internal interest rate to reflect the new credit balance
            tokenState.updateInterestRates()

            return <- reserveVault.withdraw(amount: amount)
        }

        // Returns the health of the given position, which is the ratio of the position's effective collateral
        // to its debt (as denominated in the default token). ("Effective collateral" means the
        // value of each credit balance times the liquidation threshold for that token. i.e. the maximum borrowable amount)
        access(all) fun positionHealth(pid: UInt64): UFix64 {
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var totalDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    effectiveCollateral = effectiveCollateral + trueBalance * self.liquidationThresholds[type]!
                } else {
                    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    totalDebt = totalDebt + trueBalance
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            if totalDebt == 0.0 {
                return 1.0
            }
            return effectiveCollateral / totalDebt
        }

        access(all) fun createPosition(): UInt64 {
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] = InternalPosition()
            return id
        }

        // Helper function for testing – returns the current reserve balance for the specified token type.
        access(all) fun reserveBalance(type: Type): UFix64 {
            // CHANGE: Handle case where no vault exists yet for this token type
            let vaultRef = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
            if vaultRef == nil {
                return 0.0
            }
            return vaultRef!.balance
        }

        // Add getPositionDetails function that's used by DFB implementations
        access(all) fun getPositionDetails(pid: UInt64): PositionDetails {
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let balances: [PositionBalance] = []
            
            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
                
                let trueBalance = balance.direction == BalanceDirection.Credit
                    ? AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.creditInterestIndex)
                    : AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.debitInterestIndex)
                
                balances.append(PositionBalance(
                    type: type,
                    direction: balance.direction,
                    balance: trueBalance
                ))
            }
            
            let health = self.positionHealth(pid: pid)
            
            return PositionDetails(
                balances: balances,
                poolDefaultToken: self.defaultToken,
                defaultTokenAvailableBalance: 0.0, // TODO: Calculate this properly
                health: health
            )
        }
    }

    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        // Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            return []
        }

        // Returns the maximum amount of the given token type that could be withdrawn from this position.
        access(all) fun getAvailableBalance(type: Type): UFix64 {
            return 0.0
        }

        // Returns the maximum amount of the given token type that could be deposited into this position.
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            return 0.0
        }
        // Deposits tokens into the position, paying down debt (if one exists) and/or
        // increasing collateral. The provided Vault must be a supported token type.
        access(all) fun deposit(from: @{FungibleToken.Vault})
        {
            destroy from
        }

        // Withdraws tokens from the position by withdrawing collateral and/or
        // creating/increasing a loan. The requested Vault type must be a supported token.
        access(all) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault}
        {
            // CHANGE: This is a stub implementation - real implementation would call pool.withdraw
            panic("Position.withdraw is not implemented - use Pool.withdraw directly")
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            let pool = self.pool.borrow()!
            return AlpenFlowSink(pool: pool, positionID: self.id)
        }

        // Returns a NEW source for the given token type that will service withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        access(all) fun createSource(type: Type): {DFB.Source} {
            let pool = self.pool.borrow()!
            return AlpenFlowSource(pool: pool, positionID: self.id, tokenType: type)
        }

        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(all) fun provideSink(sink: {DFB.Sink}?) {
        }

        // Provides a source to the Position that will have tokens proactively pulled from it when the
        // position has insufficient collateral. If the source can cover the position's debt, the position
        // will not be liquidated.
        //
        // Each position can have only one source, and the source must accept the default token type
        // configured for the pool. Providing a new source will replace the existing source. Pass nil
        // to configure the position to not pull tokens.
        access(all) fun provideSource(source: {DFB.Source}?) {
        }

        init(id: UInt64, pool: Capability<auth(EPosition) & Pool>) {
            self.id = id
            self.pool = pool
        }
    }

    // CHANGE: Removed FlowToken-specific implementation
    // Helper for unit-tests – creates a new Pool with a generic default token
    // Tests should specify the actual token type they want to use
    access(all) fun createTestPool(defaultTokenThreshold: UFix64): @Pool {
        // For backward compatibility, we'll panic here
        // Tests should use createPool with explicit token type
        panic("Use createPool with explicit token type instead")
    }

    // CHANGE: Removed - tests should use proper token minting
    // This function is kept for backward compatibility but will panic
    access(all) fun createTestVault(balance: UFix64): @{FungibleToken.Vault} {
        panic("Use proper token minting instead of createTestVault")
    }

    // CHANGE: Add a proper pool creation function for tests
    access(all) fun createPool(defaultToken: Type, defaultTokenThreshold: UFix64): @Pool {
        return <- create Pool(defaultToken: defaultToken, defaultTokenThreshold: defaultTokenThreshold)
    }

    // Helper for unit-tests - initializes a pool with a vault containing the specified balance
    access(all) fun createTestPoolWithBalance(defaultTokenThreshold: UFix64, initialBalance: UFix64): @Pool {
        // CHANGE: This function is deprecated - tests should create pools with explicit token types
        panic("Use createPool with explicit token type and deposit tokens separately")
    }

    // DFB.Sink implementation for AlpenFlow
    access(all) struct AlpenFlowSink: DFB.Sink {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(contract) let pool: auth(EPosition) &Pool
        access(contract) let positionID: UInt64
        
        access(all) view fun getSinkType(): Type {
            // CHANGE: For now, return a generic FungibleToken.Vault type
            // The actual type depends on what tokens the pool accepts
            return Type<@{FungibleToken.Vault}>()
        }

        access(all) fun minimumCapacity(): UFix64 {
            // For now, return 0 as there's no minimum
            return 0.0
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let amount = from.balance
            if amount > 0.0 {
                let vault <- from.withdraw(amount: amount)
                self.pool.deposit(pid: self.positionID, funds: <-vault)
            }
        }
        
        init(pool: auth(EPosition) &Pool, positionID: UInt64) {
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
        }
    }

    // DFB.Source implementation for AlpenFlow
    access(all) struct AlpenFlowSource: DFB.Source {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(contract) let pool: auth(EPosition) &Pool
        access(contract) let positionID: UInt64
        access(contract) let tokenType: Type
        
        access(all) view fun getSourceType(): Type {
            return self.tokenType
        }

        access(all) fun minimumAvailable(): UFix64 {
            // Return the available balance for withdrawal
            let position = self.pool.getPositionDetails(pid: self.positionID)
            for balance in position.balances {
                if balance.type == self.tokenType && balance.direction == BalanceDirection.Credit {
                    return balance.balance
                }
            }
            return 0.0
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let available = self.minimumAvailable()
            let withdrawAmount = available < maxAmount ? available : maxAmount
            if withdrawAmount > 0.0 {
                return <- self.pool.withdraw(pid: self.positionID, amount: withdrawAmount, type: self.tokenType)
            } else {
                return <- AlpenFlow.createEmptyVault(vaultType: self.tokenType)
            }
        }
        
        init(pool: auth(EPosition) &Pool, positionID: UInt64, tokenType: Type) {
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
            self.tokenType = tokenType
        }
    }

    // AlpenFlow starts here!

    access(all) enum BalanceDirection: UInt8 {
        access(all) case Credit
        access(all) case Debit
    }

    // A structure returned externally to report a position's balance for a particular token.
    // This structure is NOT used internally.
    access(all) struct PositionBalance {
        access(all) let type: Type
        access(all) let direction: BalanceDirection
        access(all) let balance: UFix64

        init(type: Type, direction: BalanceDirection, balance: UFix64) {
            self.type = type
            self.direction = direction
            self.balance = balance
        }
    }

    // A structure returned externally to report all of the details associated with a position.
    // This structure is NOT used internally.
    access(all) struct PositionDetails {
        access(all) let balances: [PositionBalance]
        access(all) let poolDefaultToken: Type
        access(all) let defaultTokenAvailableBalance: UFix64
        access(all) let health: UFix64

        init(balances: [PositionBalance], poolDefaultToken: Type, defaultTokenAvailableBalance: UFix64, health: UFix64) {
            self.balances = balances
            self.poolDefaultToken = poolDefaultToken
            self.defaultTokenAvailableBalance = defaultTokenAvailableBalance
            self.health = health
        }
    }
}