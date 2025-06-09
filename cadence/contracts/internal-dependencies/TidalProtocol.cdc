import "Burner"
import "FungibleToken"
import "ViewResolver"
import "MetadataViews"
import "FungibleTokenMetadataViews"

import "DFBUtils"
import "DFB"
import "MOET"

access(all) contract TidalProtocol {

    /// The canonical StoragePath where the primary TidalProtocol Pool is stored
    access(all) let PoolStoragePath: StoragePath
    /// The canonical StoragePath where the PoolFactory resource is stored
    access(all) let PoolFactoryPath: StoragePath
    /// The canonical PublicPath where the primary TidalProtocol Pool can be accessed publicly
    access(all) let PoolPublicPath: PublicPath

    /* --- PUBLIC METHODS ---- */

    /// Takes out a TidalProtocol loan with the provided collateral, returning a Position that can be used to manage
    /// collateral and borrowed fund flows
    ///
    /// @param collateral: The collateral used as the basis for a loan. Only certain collateral types are supported, so
    ///     callers should be sure to check the provided Vault is supported to prevent reversion.
    /// @param issuanceSink: The DeFiBlocks Sink connector where the protocol will deposit borrowed funds. If the
    ///     position becomes overcollateralized, additional funds will be borrowed (to maintain target LTV) and
    ///     deposited to the provided Sink.
    /// @param repaymentSource: An optional DeFiBlocks Source connector from which the protocol will attempt to source
    ///     borrowed funds in the event of undercollateralization prior to liquidating. If none is provided, the
    ///     position health will not be actively managed on the down side, meaning liquidation is possible as soon as
    ///     the loan becomes undercollateralized.
    ///
    /// @return the Position via which the caller can manage their position
    ///
    access(all) fun openPosition(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DFB.Sink},
        repaymentSource: {DFB.Source}?,
        pushToDrawDownSink: Bool
    ): Position {
        let pid = self.borrowPool().createPosition(
                funds: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        let cap = self.account.capabilities.storage.issue<auth(EPosition) &Pool>(self.PoolStoragePath)
        return Position(id: pid, pool: cap)
    }

    /* --- CONSTRUCTS & INTERNAL METHODS ---- */

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

    // RESTORED: BalanceSheet and health computation from Dieter's implementation
    // A convenience function for computing a health value from effective collateral and debt values.
    access(all) fun healthComputation(effectiveCollateral: UFix64, effectiveDebt: UFix64): UFix64 {
        var health = 0.0

        if effectiveCollateral == 0.0 {
            health = 0.0
        } else if effectiveDebt == 0.0 {
            health = UFix64.max
        } else if (effectiveDebt / effectiveCollateral) == 0.0 {
            // If debt is so small relative to collateral that division rounds to zero,
            // the health is essentially infinite
            health = UFix64.max
        } else {
            health = effectiveCollateral / effectiveDebt
        }

        return health
    }

    access(all) struct BalanceSheet {
        access(all) let effectiveCollateral: UFix64
        access(all) let effectiveDebt: UFix64
        access(all) let health: UFix64

        init(effectiveCollateral: UFix64, effectiveDebt: UFix64) {
            self.effectiveCollateral = effectiveCollateral
            self.effectiveDebt = effectiveDebt
            self.health = TidalProtocol.healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }
    }

    // A structure used internally to track a position's balance for a particular token.
    access(all) struct InternalBalance {
        access(all) var direction: BalanceDirection

        // Internally, position balances are tracked using a "scaled balance". The "scaled balance" is the
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
                let scaledDeposit = TidalProtocol.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.creditInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledDeposit

                // Increase the total credit balance for the token
                tokenState.updateCreditBalance(amount: Fix64(amount))
            } else {
                // When depositing into a debit position, we first need to compute the true balance to see
                // if this deposit will flip the position from debit to credit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.debitInterestIndex)

                if trueBalance > amount {
                    // The deposit isn't big enough to clear the debt, so we just decrement the debt.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the total debit balance for the token
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The deposit is enough to clear the debt, so we switch to a credit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Credit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
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
                let scaledWithdrawal = TidalProtocol.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.debitInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledWithdrawal

                // Increase the total debit balance for the token
                tokenState.updateDebitBalance(amount: Fix64(amount))
            } else {
                // When withdrawing from a credit position, we first need to compute the true balance to see
                // if this withdrawal will flip the position from credit to debit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.creditInterestIndex)

                if trueBalance >= amount {
                    // The withdrawal isn't big enough to push the position into debt, so we just decrement the
                    // credit balance.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Decrease the total credit balance for the token
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The withdrawal is enough to push the position into debt, so we switch to a debit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Debit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
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
        EImplementation -> FungibleToken.Withdraw
    }

    // RESTORED: InternalPosition as resource per Dieter's design
    // This MUST be a resource to properly manage queued deposits
    access(all) resource InternalPosition {
        access(EImplementation) var targetHealth: UFix64
        access(EImplementation) var minHealth: UFix64
        access(EImplementation) var maxHealth: UFix64
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
        access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {FungibleToken.Vault}}
        access(mapping ImplementationUpdates) var drawDownSink: {DFB.Sink}?
        access(mapping ImplementationUpdates) var topUpSource: {DFB.Source}?

        init() {
            self.balances = {}
            self.queuedDeposits <- {}
            self.targetHealth = 1.3
            self.minHealth = 1.1
            self.maxHealth = 1.5
            self.drawDownSink = nil
            self.topUpSource = nil
        }

        access(EImplementation) fun setDrawDownSink(_ sink: {DFB.Sink}?) {
            pre {
                sink?.getSinkType() ?? Type<@MOET.Vault>() == Type<@MOET.Vault>():
                "Invalid Sink provided - Sink \(sink.getType().identifier) must accept MOET"
            }
            self.drawDownSink = sink
        }

        access(EImplementation) fun setTopUpSource(_ source: {DFB.Source}?) {
            self.topUpSource = source
        }
    }

    access(all) struct interface InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64 {
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
                result = TidalProtocol.interestMul(result, current)
            }
            current = TidalProtocol.interestMul(current, current)
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

        // RESTORED: Deposit rate limiting from Dieter's implementation
        access(all) var depositRate: UFix64
        access(all) var depositCapacity: UFix64
        access(all) var depositCapacityCap: UFix64

        access(all) fun updateCreditBalance(amount: Fix64) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalCreditBalance) + amount
            self.totalCreditBalance = adjustedBalance > 0.0 ? UFix64(adjustedBalance) : 0.0
        }

        access(all) fun updateDebitBalance(amount: Fix64) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalDebitBalance) + amount
            self.totalDebitBalance = adjustedBalance > 0.0 ? UFix64(adjustedBalance) : 0.0
        }

        // RESTORED: Enhanced updateInterestIndices with deposit capacity update
        access(all) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta = currentTime - self.lastUpdate
            self.creditInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
            self.debitInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
            self.lastUpdate = currentTime

            // RESTORED: Update deposit capacity based on time
            let newDepositCapacity = self.depositCapacity + (self.depositRate * timeDelta)
            if newDepositCapacity >= self.depositCapacityCap {
                self.depositCapacity = self.depositCapacityCap
            } else {
                self.depositCapacity = newDepositCapacity
            }
        }

        // RESTORED: Deposit limit function from Dieter's implementation
        access(all) fun depositLimit(): UFix64 {
            // Each deposit is limited to 5% of the total deposit capacity
            return self.depositCapacity * 0.05
        }

        // RESTORED: Rename to updateForTimeChange to match Dieter's implementation
        access(all) fun updateForTimeChange() {
            self.updateInterestIndices()
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

            self.currentCreditRate = TidalProtocol.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = TidalProtocol.perSecondInterestRate(yearlyRate: debitRate)
        }

        // RESTORED: Parameterized init from Dieter's implementation
        init(interestCurve: {InterestCurve}, depositRate: UFix64, depositCapacityCap: UFix64) {
            self.lastUpdate = getCurrentBlock().timestamp
            self.totalCreditBalance = 0.0
            self.totalDebitBalance = 0.0
            self.creditInterestIndex = 10000000000000000
            self.debitInterestIndex = 10000000000000000
            self.currentCreditRate = 10000000000000000
            self.currentDebitRate = 10000000000000000
            self.interestCurve = interestCurve
            self.depositRate = depositRate
            self.depositCapacity = depositCapacityCap
            self.depositCapacityCap = depositCapacityCap
        }
    }

    access(all) resource Pool {
        // A simple version number that is incremented whenever one or more interest indices
        // are updated. This is used to detect when the interest indices need to be updated in
        // InternalPositions.
        access(EImplementation) var version: UInt64

        // Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}

        // Individual user positions - RESTORED as resources per Dieter's design
        access(self) var positions: @{UInt64: InternalPosition}

        // The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}

        // Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64

        // The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        // RESTORED: Price oracle from Dieter's implementation
        // A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {DFB.PriceOracle}

        // RESTORED: Position update queue from Dieter's implementation
        access(EImplementation) var positionsNeedingUpdates: [UInt64]
        access(self) var positionsProcessedPerCallback: UInt64

        // RESTORED: Collateral and borrow factors from Dieter's implementation
        // These dictionaries determine borrowing limits. Each token has a collateral factor and a
        // borrow factor.
        //
        // When determining the total collateral amount that can be borrowed against, the value of the
        // token (as given by the oracle) is multiplied by the collateral factor. So, a token with a
        // collateral factor of 0.8 would only allow you to borrow 80% as much as if you had a the same
        // value of a token with a collateral factor of 1.0. The total "effective collateral" for a
        // position is the value of each token multiplied by its collateral factor.
        //
        // At the same time, the "borrow factor" determines if the user can borrow against all of that
        // effective collateral, or if they can only borrow a portion of it to manage risk.
        access(self) var collateralFactor: {Type: UFix64}
        access(self) var borrowFactor: {Type: UFix64}

        // REMOVED: Static exchange rates and liquidation thresholds
        // These have been replaced by dynamic oracle pricing and risk factors

        // RESTORED: tokenState() helper function from Dieter's implementation
        // A convenience function that returns a reference to a particular token state, making sure
        // it's up-to-date for the passage of time. This should always be used when accessing a token
        // state to avoid missing interest updates (duplicate calls to updateForTimeChange() are a nop
        // within a single block).
        access(self) fun tokenState(type: Type): auth(EImplementation) &TokenState {
            let state = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            state.updateForTimeChange()
            return state
        }

        init(defaultToken: Type, priceOracle: {DFB.PriceOracle}) {
            pre {
                priceOracle.unitOfAccount() == defaultToken: "Price oracle must return prices in terms of the default token"
            }

            self.version = 0
            self.globalLedger = {defaultToken: TokenState(
                interestCurve: SimpleInterestCurve(),
                depositRate: 1000000.0,        // Default: no rate limiting for default token
                depositCapacityCap: 1000000.0  // Default: high capacity cap
            )}
            self.positions <- {}
            self.reserves <- {}
            self.defaultToken = defaultToken
            self.priceOracle = priceOracle
            self.collateralFactor = {defaultToken: 1.0}
            self.borrowFactor = {defaultToken: 1.0}
            self.nextPositionID = 0
            self.positionsNeedingUpdates = []
            self.positionsProcessedPerCallback = 100

            // CHANGE: Don't create vault here - let the caller provide initial reserves
            // The pool starts with empty reserves map
            // Vaults will be added when tokens are first deposited
        }

        // Add a new token type to the pool
        // This function should only be called by governance in the future
        access(EGovernance) fun addSupportedToken(
            tokenType: Type,
            collateralFactor: UFix64,
            borrowFactor: UFix64,
            interestCurve: {InterestCurve},
            depositRate: UFix64,
            depositCapacityCap: UFix64
        ) {
            pre {
                self.globalLedger[tokenType] == nil: "Token type already supported"
                tokenType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Invalid token type \(tokenType.identifier) - tokenType must be a FungibleToken Vault implementation"
                collateralFactor > 0.0 && collateralFactor <= 1.0: "Collateral factor must be between 0 and 1"
                borrowFactor > 0.0 && borrowFactor <= 1.0: "Borrow factor must be between 0 and 1"
                depositRate > 0.0: "Deposit rate must be positive"
                depositCapacityCap > 0.0: "Deposit capacity cap must be positive"
                DFBUtils.definingContractIsFungibleToken(tokenType):
                "Invalid token contract definition for tokenType \(tokenType.identifier) - defining contract is not FungibleToken conformant"
            }

            // Add token to global ledger with its interest curve and deposit parameters
            self.globalLedger[tokenType] = TokenState(
                interestCurve: interestCurve,
                depositRate: depositRate,
                depositCapacityCap: depositCapacityCap
            )

            // Set collateral factor (what percentage of value can be used as collateral)
            self.collateralFactor[tokenType] = collateralFactor

            // Set borrow factor (risk adjustment for borrowed amounts)
            self.borrowFactor[tokenType] = borrowFactor
        }

        // Get supported token types
        access(all) fun getSupportedTokens(): [Type] {
            return self.globalLedger.keys
        }

        // Check if a token type is supported
        access(all) fun isTokenSupported(tokenType: Type): Bool {
            return self.globalLedger[tokenType] != nil
        }

        // RESTORED: Public deposit function from Dieter's implementation
        // Allows anyone to deposit funds into any position
        access(all) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
            self.depositAndPush(pid: pid, from: <-from, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced deposit with queue processing and rebalancing from Dieter's implementation
        access(EPosition) fun depositAndPush(pid: UInt64, from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[from.getType()] != nil: "Invalid token type"
            }

            if from.balance == 0.0 {
                Burner.burn(<-from)
                return
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = from.getType()
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            // Update time-based state
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // RESTORED: Deposit rate limiting from Dieter's implementation
            let depositAmount = from.balance
            let depositLimit = tokenState.depositLimit()

            if depositAmount > depositLimit {
                // The deposit is too big, so we need to queue the excess
                let queuedDeposit <- from.withdraw(amount: depositAmount - depositLimit)

                if position.queuedDeposits[type] == nil {
                    position.queuedDeposits[type] <-! queuedDeposit
                } else {
                    position.queuedDeposits[type]!.deposit(from: <-queuedDeposit)
                }
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // CHANGE: Create vault if it doesn't exist yet
            if self.reserves[type] == nil {
                self.reserves[type] <-! from.createEmptyVault()
            }
            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the deposit in the position's balance
            position.balances[type]!.recordDeposit(amount: from.balance, tokenState: tokenState)

            // Add the money to the reserves
            reserveVault.deposit(from: <-from)

            // RESTORED: Rebalancing and queue management
            if pushToDrawDownSink {
                self.rebalancePosition(pid: pid, force: true)
            }

            self.queuePositionForUpdateIfNecessary(pid: pid)
        }

        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            // RESTORED: Call the enhanced function with pullFromTopUpSource = false for backward compatibility
            return <- self.withdrawAndPull(pid: pid, type: type, amount: amount, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced withdraw with top-up source integration from Dieter's implementation
        access(EPosition) fun withdrawAndPull(
            pid: UInt64,
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
            }
            if amount == 0.0 {
                return <- DFBUtils.getEmptyVault(type)
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            // Update the global interest indices on the affected token to reflect the passage of time.
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // RESTORED: Top-up source integration from Dieter's implementation
            // Preflight to see if the funds are available
            let topUpSource = position.topUpSource as auth(FungibleToken.Withdraw) &{DFB.Source}?
            let topUpType = topUpSource?.getSourceType() ?? self.defaultToken

            let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: topUpType,
                targetHealth: position.minHealth,
                withdrawType: type,
                withdrawAmount: amount
            )

            var canWithdraw = false

            if requiredDeposit == 0.0 {
                // We can service this withdrawal without any top up
                canWithdraw = true
            } else {
                // We need more funds to service this withdrawal, see if they are available from the top up source
                if pullFromTopUpSource && topUpSource != nil {
                    // If we have to rebalance, let's try to rebalance to the target health, not just the minimum
                    let idealDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                        pid: pid,
                        depositType: topUpType,
                        targetHealth: position.targetHealth,
                        withdrawType: type,
                        withdrawAmount: amount
                    )

                    let pulledVault <- topUpSource!.withdrawAvailable(maxAmount: idealDeposit)

                    // NOTE: We requested the "ideal" deposit, but we compare against the required deposit here.
                    // The top up source may not have enough funds get us to the target health, but could have
                    // enough to keep us over the minimum.
                    if pulledVault.balance >= requiredDeposit {
                        // We can service this withdrawal if we deposit funds from our top up source
                        self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                        canWithdraw = true
                    } else {
                        // We can't get the funds required to service this withdrawal, so we need to redeposit what we got
                        self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                    }
                }
            }

            if !canWithdraw {
                // We can't service this withdrawal, so we just abort
                panic("Cannot withdraw \(amount) of \(type.identifier) from position ID \(pid) - Insufficient funds for withdrawal")
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            position.balances[type]!.recordWithdrawal(amount: amount, tokenState: tokenState)

            // Ensure that this withdrawal doesn't cause the position to be overdrawn.
            assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")

            // Queue for update if necessary
            self.queuePositionForUpdateIfNecessary(pid: pid)

            return <- reserveVault.withdraw(amount: amount)
        }

        // RESTORED: Position queue management from Dieter's implementation
        access(self) fun queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.positionsNeedingUpdates.contains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            } else {
                // If this position is not already queued for an update, we need to check if it needs one
                let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

                if position.queuedDeposits.length > 0 {
                    // This position has deposits that need to be processed, so we need to queue it for an update
                    self.positionsNeedingUpdates.append(pid)
                    return
                }

                let positionHealth = self.positionHealth(pid: pid)

                if positionHealth < position.minHealth || positionHealth > position.maxHealth {
                    // This position is outside the configured health bounds, we queue it for an update
                    self.positionsNeedingUpdates.append(pid)
                    return
                }
            }
        }

        // RESTORED: Position rebalancing from Dieter's implementation
        // Rebalances the position to the target health value. If force is true, the position will be
        // rebalanced even if it is currently healthy, otherwise, this function will do nothing if the
        // position is within the min/max health bounds.
        access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            if !force && (balanceSheet.health >= position.minHealth && balanceSheet.health <= position.maxHealth) {
                // We aren't forcing the update, and the position is already between its desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.targetHealth {
                // The position is undercollateralized, see if the source can get more collateral to bring it up to the target health.
                if position.topUpSource != nil {
                    let topUpSource = position.topUpSource! as auth(FungibleToken.Withdraw) &{DFB.Source}
                    let idealDeposit = self.fundsRequiredForTargetHealth(
                        pid: pid,
                        type: topUpSource.getSourceType(),
                        targetHealth: position.targetHealth
                    )

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                }
            } else if balanceSheet.health > position.targetHealth {
                // The position is overcollateralized, we'll withdraw funds to match the target health and offer it to the sink.
                if position.drawDownSink != nil {
                    let drawDownSink = position.drawDownSink!
                    let sinkType = drawDownSink.getSinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(
                        pid: pid,
                        type: sinkType,
                        targetHealth: position.targetHealth
                    )

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.minimumCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal

                    if sinkAmount > 0.0 && sinkType == self.defaultToken { // second conditional included for sake of tracer bullet
                        // BUG: Calling through to withdrawAndPull results in an insufficient funds from the position's
                        //      topUpSource. These funds should come from the protocol or reserves, not from the user's
                        //      funds. To unblock here, we just mint MOET when a position is overcollateralized
                        // let sinkVault <- self.withdrawAndPull(
                        //     pid: pid,
                        //     type: sinkType,
                        //     amount: sinkAmount,
                        //     pullFromTopUpSource: false
                        // )

                        let tokenState = self.tokenState(type: self.defaultToken)
                        if position.balances[self.defaultToken] == nil {
                            position.balances[self.defaultToken] = InternalBalance()
                        }
                        position.balances[self.defaultToken]!.recordWithdrawal(amount: sinkAmount, tokenState: tokenState)
                        let sinkVault <- TidalProtocol.borrowMOETMinter().mintTokens(amount: sinkAmount)
                        // Push what we can into the sink, and redeposit the rest
                        drawDownSink.depositCapacity(from: &sinkVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

                        if sinkVault.balance > 0.0 {
                            self.depositAndPush(pid: pid, from: <-sinkVault, pushToDrawDownSink: false)
                        } else {
                            Burner.burn(<-sinkVault)
                        }
                    }
                }
            }
        }

        // RESTORED: Provider functions for sink/source from Dieter's implementation
        access(EPosition) fun provideDrawDownSink(pid: UInt64, sink: {DFB.Sink}?) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            position.setDrawDownSink(sink)
        }

        access(EPosition) fun provideTopUpSource(pid: UInt64, source: {DFB.Source}?) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            position.setTopUpSource(source)
        }

        // RESTORED: Available balance with source integration from Dieter's implementation
        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            if pullFromTopUpSource && position.topUpSource != nil {
                let topUpSource = position.topUpSource!
                let sourceType = topUpSource.getSourceType()
                let sourceAmount = topUpSource.minimumAvailable()

                return self.fundsAvailableAboveTargetHealthAfterDepositing(
                    pid: pid,
                    withdrawType: type,
                    targetHealth: position.minHealth,
                    depositType: sourceType,
                    depositAmount: sourceAmount
                )
            } else {
                return self.fundsAvailableAboveTargetHealth(
                    pid: pid,
                    type: type,
                    targetHealth: position.minHealth
                )
            }
        }

        // Returns the health of the given position, which is the ratio of the position's effective collateral
        // to its debt (as denominated in the default token). ("Effective collateral" means the
        // value of each credit balance times the liquidation threshold for that token. i.e. the maximum borrowable amount)
        access(all) fun positionHealth(pid: UInt64): UFix64 {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // RESTORED: Oracle-based pricing from Dieter's implementation
                    let tokenPrice = self.priceOracle.price(ofToken: type)!
                    let value = tokenPrice * trueBalance
                    effectiveCollateral = effectiveCollateral + (value * self.collateralFactor[type]!)
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // RESTORED: Oracle-based pricing for debt calculation
                    let tokenPrice = self.priceOracle.price(ofToken: type)!
                    let value = tokenPrice * trueBalance
                    effectiveDebt = effectiveDebt + (value / self.borrowFactor[type]!)
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            if effectiveDebt == 0.0 {
                return 1.0
            }
            return effectiveCollateral / effectiveDebt
        }

        // RESTORED: Position balance sheet calculation from Dieter's implementation
        access(self) fun positionBalanceSheet(pid: UInt64): BalanceSheet {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let priceOracle = &self.priceOracle as &{DFB.PriceOracle}

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    let value = priceOracle.price(ofToken: type)! * trueBalance

                    effectiveCollateral = effectiveCollateral + (value * self.collateralFactor[type]!)
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    let value = priceOracle.price(ofToken: type)! * trueBalance

                    effectiveDebt = effectiveDebt + (value / self.borrowFactor[type]!)
                }
            }

            return BalanceSheet(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }

        /// Creates a lending position against the provided collateral funds, depositing the loaned amount to the
        /// given Sink. If a Source is provided, the position will be configured to pull loan repayment when the loan
        /// becomes undercollateralized, preferring repayment to outright liquidation.
        access(all) fun createPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DFB.Sink},
            repaymentSource: {DFB.Source}?,
            pushToDrawDownSink: Bool
        ): UInt64 {
            pre {
                self.globalLedger[funds.getType()] != nil: "Invalid token type \(funds.getType().identifier)"
            }
            // construct a new InternalPosition, assigning it the current position ID
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] <-! create InternalPosition()


            // assign issuance & repayment connectors within the InternalPosition
            let iPos = (&self.positions[id] as auth(EImplementation) &InternalPosition?)!
            let fundsType = funds.getType()
            iPos.setDrawDownSink(issuanceSink)
            if repaymentSource != nil {
                iPos.setTopUpSource(repaymentSource)
            }

            // deposit the initial funds & return the position ID
            self.depositAndPush(
                pid: id,
                from: <-funds,
                pushToDrawDownSink: pushToDrawDownSink
            )
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
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let balances: [PositionBalance] = []

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)

                let trueBalance = balance.direction == BalanceDirection.Credit
                    ? TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.creditInterestIndex)
                    : TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.debitInterestIndex)

                balances.append(PositionBalance(
                    type: type,
                    direction: balance.direction,
                    balance: trueBalance
                ))
            }

            let health = self.positionHealth(pid: pid)
            let defaultTokenAvailable = self.availableBalance(pid: pid, type: self.defaultToken, pullFromTopUpSource: false)

            return PositionDetails(
                balances: balances,
                poolDefaultToken: self.defaultToken,
                defaultTokenAvailableBalance: defaultTokenAvailable,
                health: health
            )
        }

        // RESTORED: Advanced position health management functions from Dieter's implementation

        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health. This function will return 0.0 if the position is already at or over
        // that health value.
        access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: type,
                targetHealth: targetHealth,
                withdrawType: self.defaultToken,
                withdrawAmount: 0.0
            )
        }

        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health assuming we also withdraw a specified amount of another
        // token. This function will return 0.0 if the position would already be at or over the target
        // health value after the proposed withdrawal.
        access(all) fun fundsRequiredForTargetHealthAfterWithdrawing(
            pid: UInt64,
            depositType: Type,
            targetHealth: UFix64,
            withdrawType: Type,
            withdrawAmount: UFix64
        ): UFix64 {
            if depositType == withdrawType && withdrawAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the required deposit assuming
                // no withdrawal (which is less work) and increase that by the withdraw amount at the end
                return self.fundsRequiredForTargetHealth(pid: pid, type: depositType, targetHealth: targetHealth) + withdrawAmount
            }

            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt


            if withdrawAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If the position doesn't have any collateral for the withdrawn token, we can just compute how much
                    // additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                        (withdrawAmount * self.priceOracle.price(ofToken: withdrawType)! / self.borrowFactor[withdrawType]!)
                } else {
                    let withdrawTokenState = self.tokenState(type: withdrawType)
                    // REMOVED: This is now handled by tokenState() helper function
                    // withdrawTokenState.updateForTimeChange()

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let collateralBalance = position.balances[withdrawType]!.scaledBalance
                    let trueCollateral = TidalProtocol.scaledBalanceToTrueBalance(
                        scaledBalance: collateralBalance,
                        interestIndex: withdrawTokenState.creditInterestIndex
                    )

                    if trueCollateral >= withdrawAmount {
                        // This withdrawal will draw down collateral, but won't create debt, we just need to account
                        // for the collateral decrease.
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            (withdrawAmount * self.priceOracle.price(ofToken: withdrawType)! * self.collateralFactor[withdrawType]!)
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create some debt.
                        effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                            ((withdrawAmount - trueCollateral) * self.priceOracle.price(ofToken: withdrawType)! / self.borrowFactor[withdrawType]!)

                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            (trueCollateral * self.priceOracle.price(ofToken: withdrawType)! * self.collateralFactor[withdrawType]!)
                    }
                }
            }

            // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
            // Now we can figure out how many of the given token would need to be deposited to bring the position
            // to the target health value.
            var healthAfterWithdrawal = TidalProtocol.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )

            if healthAfterWithdrawal >= targetHealth {
                // The position is already at or above the target health, so we don't need to deposit anything.
                return 0.0
            }

            // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
            // track of the number of tokens that went towards paying off debt.
            var debtTokenCount = 0.0

            if position.balances[depositType] != nil && position.balances[depositType]!.direction == BalanceDirection.Debit {
                // The user has a debt position in the given token, we start by looking at the health impact of paying off
                // the entire debt.
                let depositTokenState = self.tokenState(type: depositType)
                // REMOVED: This is now handled by tokenState() helper function
                // depositTokenState.updateForTimeChange()

                let debtBalance = position.balances[depositType]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: debtBalance,
                    interestIndex: depositTokenState.debitInterestIndex
                )
                let debtEffectiveValue = self.priceOracle.price(ofToken: depositType)! * trueDebt / self.borrowFactor[depositType]!

                // Check what the new health would be if we paid off all of this debt
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterWithdrawal,
                    effectiveDebt: effectiveDebtAfterWithdrawal - debtEffectiveValue
                )

                // Does paying off all of the debt reach the target health? Then we're done.
                if potentialHealth >= targetHealth {
                    // We can reach the target health by paying off some or all of the debt. We can easily
                    // compute how many units of the token would be needed to reach the target health.
                    let healthChange = targetHealth - healthAfterWithdrawal
                    let requiredEffectiveDebt = healthChange * effectiveCollateralAfterWithdrawal / (targetHealth * targetHealth)

                    // The amount of the token to pay back, in units of the token.
                    let paybackAmount = requiredEffectiveDebt * self.borrowFactor[depositType]! / self.priceOracle.price(ofToken: depositType)!

                    return paybackAmount
                } else {
                    // We can pay off the entire debt, but we still need to deposit more to reach the target health.
                    // We have logic below that can determine the collateral deposition required to reach the target health
                    // from this new health position. Rather than copy that logic here, we fall through into it. But first
                    // we have to record the amount of tokens that went towards debt payback and adjust the effective
                    // debt to reflect that it has been paid off.
                    debtTokenCount = trueDebt
                    effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
                    healthAfterWithdrawal = potentialHealth
                }
            }

            // At this point, we're either dealing with a position that didn't have a debt position in the deposit
            // token, or we've accounted for the debt payoff and adjusted the effective debt above.

            // Now we need to figure out how many tokens would need to be deposited (as collateral) to reach the
            // target health. We can rearrange the health equation to solve for the required collateral:
            // targetHealth = effectiveCollateral / effectiveDebt
            // targetHealth * effectiveDebt = effectiveCollateral
            // requiredCollateral = targetHealth * effectiveDebtAfterWithdrawal

            // We need to increase the effective collateral from its current value to the required value, so we
            // multiply the required health change by the effective debt, and turn that into a token amount.
            let healthChange = targetHealth - healthAfterWithdrawal
            let requiredEffectiveCollateral = healthChange * effectiveDebtAfterWithdrawal

            // The amount of the token to deposit, in units of the token.
            let collateralTokenCount = requiredEffectiveCollateral / self.priceOracle.price(ofToken: depositType)! / self.collateralFactor[depositType]!

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return collateralTokenCount + debtTokenCount
        }

        // Returns the quantity of the specified token that could be withdrawn while still keeping the position's health
        // at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(
                pid: pid,
                withdrawType: type,
                targetHealth: targetHealth,
                depositType: self.defaultToken,
                depositAmount: 0.0
            )
        }

        // Returns the quantity of the specified token that could be withdrawn while still keeping the position's health
        // at or above the provided target, assuming we also deposit a specified amount of another token.
        access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(
            pid: UInt64,
            withdrawType: Type,
            targetHealth: UFix64,
            depositType: Type,
            depositAmount: UFix64
        ): UFix64 {
            if depositType == withdrawType && depositAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the available funds assuming
                // no deposit (which is less work) and increase that by the deposit amount at the end
                return self.fundsAvailableAboveTargetHealth(pid: pid, type: withdrawType, targetHealth: targetHealth) + depositAmount
            }

            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if depositAmount != 0.0 {
                if position.balances[depositType] == nil || position.balances[depositType]!.direction == BalanceDirection.Credit {
                    // If there's no debt for the deposit token, we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                        (depositAmount * self.priceOracle.price(ofToken: depositType)! * self.collateralFactor[depositType]!)
                } else {
                    let depositTokenState = self.tokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let debtBalance = position.balances[depositType]!.scaledBalance
                    let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                        scaledBalance: debtBalance,
                        interestIndex: depositTokenState.debitInterestIndex
                    )

                    if trueDebt >= depositAmount {
                        // This deposit will pay down some debt, but won't result in net collateral, we
                        // just need to account for the debt decrease.
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            (depositAmount * self.priceOracle.price(ofToken: depositType)! / self.borrowFactor[depositType]!)
                    } else {
                        // The deposit will wipe out all of the debt, and create some collateral.
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            (trueDebt * self.priceOracle.price(ofToken: depositType)! / self.borrowFactor[depositType]!)

                        effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                            ((depositAmount - trueDebt) * self.priceOracle.price(ofToken: depositType)! * self.collateralFactor[depositType]!)
                    }
                }
            }

            // We now have new effective collateral and debt values that reflect the proposed deposit (if any!)
            // Now we can figure out how many of the withdrawal token are available while keeping the position
            // at or above the target health value.
            var healthAfterDeposit = TidalProtocol.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )

            if healthAfterDeposit <= targetHealth {
                // The position is already at or below the target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens that are available from collateral
            var collateralTokenCount = 0.0

            if position.balances[withdrawType] != nil && position.balances[withdrawType]!.direction == BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self.tokenState(type: withdrawType)
                // REMOVED: This is now handled by tokenState() helper function
                // withdrawTokenState.updateForTimeChange()

                let creditBalance = position.balances[withdrawType]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: creditBalance,
                    interestIndex: withdrawTokenState.creditInterestIndex
                )
                let collateralEffectiveValue = self.priceOracle.price(ofToken: withdrawType)! * trueCredit * self.collateralFactor[withdrawType]!

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue,
                    effectiveDebt: effectiveDebtAfterDeposit
                )

                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= targetHealth {
                    // We will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would bring the position down to the target health.
                    let availableHealth = healthAfterDeposit - targetHealth
                    let availableEffectiveValue = availableHealth * effectiveDebtAfterDeposit

                    // The amount of the token we can take using that amount of health
                    let availableTokenCount = availableEffectiveValue / self.collateralFactor[withdrawType]! / self.priceOracle.price(ofToken: withdrawType)!

                    return availableTokenCount
                } else {
                    // We can flip this credit position into a debit position, before hitting the target health.
                    // We have logic below that can determine health changes for debit positions. Rather than copy that here,
                    // fall through into it. But first we have to record the amount of tokens that are available as collateral
                    // and then adjust the effective collateral to reflect that it has come out
                    collateralTokenCount = trueCredit
                    effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                    // NOTE: The above invalidates the healthAfterDeposit value, but it's not used below...
                }
            }

            // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We can calculate the available debt increase that would bring us to the target health
            var availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit

            let availableTokens = availableDebtIncrease * self.borrowFactor[withdrawType]! / self.priceOracle.price(ofToken: withdrawType)!

            return availableTokens + collateralTokenCount
        }

        // Returns the health the position would have if the given amount of the specified token were deposited.
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            var effectiveCollateralIncrease = 0.0
            var effectiveDebtDecrease = 0.0

            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Credit {
                // Since the user has no debt in the given token, we can just compute how much
                // additional collateral this deposit will create.
                effectiveCollateralIncrease = amount * self.priceOracle.price(ofToken: type)! * self.collateralFactor[type]!
            } else {
                // The user has a debit position in the given token, we need to figure out if this deposit
                // will only pay off some of the debt, or if it will also create new collateral.
                let debtBalance = position.balances[type]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: debtBalance,
                    interestIndex: tokenState.debitInterestIndex
                )

                if trueDebt >= amount {
                    // This deposit will wipe out some or all of the debt, but won't create new collateral, we
                    // just need to account for the debt decrease.
                    effectiveDebtDecrease = amount * self.priceOracle.price(ofToken: type)! / self.borrowFactor[type]!
                } else {
                    // This deposit will wipe out all of the debt, and create new collateral.
                    effectiveDebtDecrease = trueDebt * self.priceOracle.price(ofToken: type)! / self.borrowFactor[type]!
                    effectiveCollateralIncrease = (amount - trueDebt) * self.priceOracle.price(ofToken: type)! * self.collateralFactor[type]!
                }
            }

            return TidalProtocol.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral + effectiveCollateralIncrease,
                effectiveDebt: balanceSheet.effectiveDebt - effectiveDebtDecrease
            )
        }

        // Returns health value of this position if the given amount of the specified token were withdrawn without
        // using the top up source.
        // NOTE: This method can return health values below 1.0, which aren't actually allowed. This indicates
        // that the proposed withdrawal would fail (unless a top up source is available and used).
        access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            var effectiveCollateralDecrease = 0.0
            var effectiveDebtIncrease = 0.0

            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Debit {
                // The user has no credit position in the given token, we can just compute how much
                // additional effective debt this withdrawal will create.
                effectiveDebtIncrease = amount * self.priceOracle.price(ofToken: type)! / self.borrowFactor[type]!
            } else {
                // The user has a credit position in the given token, we need to figure out if this withdrawal
                // will only draw down some of the collateral, or if it will also create new debt.
                let creditBalance = position.balances[type]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: creditBalance,
                    interestIndex: tokenState.creditInterestIndex
                )

                if trueCredit >= amount {
                    // This withdrawal will draw down some collateral, but won't create new debt, we
                    // just need to account for the collateral decrease.
                    effectiveCollateralDecrease = amount * self.priceOracle.price(ofToken: type)! * self.collateralFactor[type]!
                } else {
                    // The withdrawal will wipe out all of the collateral, and create new debt.
                    effectiveDebtIncrease = (amount - trueCredit) * self.priceOracle.price(ofToken: type)! / self.borrowFactor[type]!
                    effectiveCollateralDecrease = trueCredit * self.priceOracle.price(ofToken: type)! * self.collateralFactor[type]!
                }
            }

            return TidalProtocol.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral - effectiveCollateralDecrease,
                effectiveDebt: balanceSheet.effectiveDebt + effectiveDebtIncrease
            )
        }

        // RESTORED: Async update infrastructure from Dieter's implementation
        access(EImplementation) fun asyncUpdate() {
            // TODO: In the production version, this function should only process some positions (limited by positionsProcessedPerCallback) AND
            // it should schedule each update to run in its own callback, so a revert() call from one update (for example, if a source or
            // sink aborts) won't prevent other positions from being updated.
            var processed: UInt64 = 0
            while self.positionsNeedingUpdates.length > 0 && processed < self.positionsProcessedPerCallback {
                let pid = self.positionsNeedingUpdates.removeFirst()
                self.asyncUpdatePosition(pid: pid)
                self.queuePositionForUpdateIfNecessary(pid: pid)
                processed = processed + 1
            }
        }

        // RESTORED: Async position update from Dieter's implementation
        access(EImplementation) fun asyncUpdatePosition(pid: UInt64) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            // First check queued deposits, their addition could affect the rebalance we attempt later
            for depositType in position.queuedDeposits.keys {
                let queuedVault <- position.queuedDeposits.remove(key: depositType)!
                let queuedAmount = queuedVault.balance
                let depositTokenState = self.tokenState(type: depositType)

                let maxDeposit = depositTokenState.depositLimit()

                if maxDeposit >= queuedAmount {
                    // We can deposit all of the queued deposit, so just do it and remove it from the queue
                    self.depositAndPush(pid: pid, from: <-queuedVault, pushToDrawDownSink: false)
                } else {
                    // We can only deposit part of the queued deposit, so do that and leave the rest in the queue
                    // for the next time we run.
                    let depositVault <- queuedVault.withdraw(amount: maxDeposit)
                    self.depositAndPush(pid: pid, from: <-depositVault, pushToDrawDownSink: false)

                    // We need to update the queued vault to reflect the amount we used up
                    position.queuedDeposits[depositType] <-! queuedVault
                }
            }

            // Now that we've deposited a non-zero amount of any queued deposits, we can rebalance
            // the position if necessary.
            self.rebalancePosition(pid: pid, force: false)
        }
    }

    /// Resource enabling the contract account to create a Pool. This pattern is used in place of contract methods to
    /// ensure limited access to pool creation. While this could be done in contract's init, doing so here will allow
    /// for the setting of the Pool's PriceOracle without the introduction of a concrete PriceOracle defining contract
    /// which would include an external contract dependency.
    ///
    access(all) resource PoolFactory {
        /// Creates a Pool and saves it to the canonical path, reverting if one is already stored
        access(all) fun createPool(defaultToken: Type, priceOracle: {DFB.PriceOracle}) {
            pre {
                TidalProtocol.account.storage.type(at: TidalProtocol.PoolStoragePath) == nil:
                "Storage collision - Pool has already been created & saved to \(TidalProtocol.PoolStoragePath)"
            }
            let pool <- create Pool(defaultToken: defaultToken, priceOracle: priceOracle)
            TidalProtocol.account.storage.save(<-pool, to: TidalProtocol.PoolStoragePath)
            let cap = TidalProtocol.account.capabilities.storage.issue<&Pool>(TidalProtocol.PoolStoragePath)
            TidalProtocol.account.capabilities.unpublish(TidalProtocol.PoolPublicPath)
            TidalProtocol.account.capabilities.publish(cap, at: TidalProtocol.PoolPublicPath)
        }
    }

    // TODO: Consider making this a resource given how critical it is to accessing a loan
    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>) {
            pre {
                pool.check(): "Invalid Pool Capability provided - cannot construct Position"
            }
            self.id = id
            self.pool = pool
        }

        // Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            let pool = self.pool.borrow()!
            return pool.getPositionDetails(pid: self.id).balances
        }

        // RESTORED: Enhanced available balance from Dieter's implementation
        access(all) fun availableBalance(type: Type, pullFromTopUpSource: Bool): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        // RESTORED: Health functions from Dieter's implementation
        access(all) fun getHealth(): UFix64 {
            let pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }

        access(all) fun getTargetHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setTargetHealth(targetHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        access(all) fun getMinHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setMinHealth(minHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        access(all) fun getMaxHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setMaxHealth(maxHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        // Returns the maximum amount of the given token type that could be deposited into this position.
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }

        // RESTORED: Simple deposit that calls depositAndPush with pushToDrawDownSink = false
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced deposit from Dieter's implementation
        access(all) fun depositAndPush(from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: pushToDrawDownSink)
        }

        // RESTORED: Simple withdraw that calls withdrawAndPull with pullFromTopUpSource = false
        access(FungibleToken.Withdraw) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(type: type, amount: amount, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced withdraw from Dieter's implementation
        access(FungibleToken.Withdraw) fun withdrawAndPull(type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(pid: self.id, type: type, amount: amount, pullFromTopUpSource: pullFromTopUpSource)
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            // RESTORED: Create enhanced sink with pushToDrawDownSink option
            return self.createSinkWithOptions(type: type, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced sink creation from Dieter's implementation
        access(all) fun createSinkWithOptions(type: Type, pushToDrawDownSink: Bool): {DFB.Sink} {
            let pool = self.pool.borrow()!
            return PositionSink(id: self.id, pool: self.pool, type: type, pushToDrawDownSink: pushToDrawDownSink)
        }

        // Returns a NEW source for the given token type that will service withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        access(FungibleToken.Withdraw) fun createSource(type: Type): {DFB.Source} {
            // RESTORED: Create enhanced source with pullFromTopUpSource option
            return self.createSourceWithOptions(type: type, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced source creation from Dieter's implementation
        access(FungibleToken.Withdraw) fun createSourceWithOptions(type: Type, pullFromTopUpSource: Bool): {DFB.Source} {
            let pool = self.pool.borrow()!
            return PositionSource(id: self.id, pool: self.pool, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        // RESTORED: Provider functions implementation from Dieter's design
        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(FungibleToken.Withdraw) fun provideSink(sink: {DFB.Sink}?) {
            let pool = self.pool.borrow()!
            pool.provideDrawDownSink(pid: self.id, sink: sink)
        }

        // Provides a source to the Position that will have tokens proactively pulled from it when the
        // position has insufficient collateral. If the source can cover the position's debt, the position
        // will not be liquidated.
        //
        // Each position can have only one source, and the source must accept the default token type
        // configured for the pool. Providing a new source will replace the existing source. Pass nil
        // to configure the position to not pull tokens.
        access(all) fun provideSource(source: {DFB.Source}?) {
            let pool = self.pool.borrow()!
            pool.provideTopUpSource(pid: self.id, source: source)
        }
    }

    // RESTORED: Enhanced position sink from Dieter's implementation
    access(all) struct PositionSink: DFB.Sink {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) let pool: Capability<auth(EPosition) &Pool>
        access(self) let positionID: UInt64
        access(self) let type: Type
        access(self) let pushToDrawDownSink: Bool

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pushToDrawDownSink: Bool) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pushToDrawDownSink = pushToDrawDownSink
        }

        access(all) view fun getSinkType(): Type {
            return self.type
        }

        access(all) fun minimumCapacity(): UFix64 {
            // A position object has no limit to deposits unless the Capability has been revoked
            return self.pool.check() ? UFix64.max : 0.0
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let pool = self.pool.borrow() {
                pool.depositAndPush(
                    pid: self.positionID,
                    from: <-from.withdraw(amount: from.balance),
                    pushToDrawDownSink: self.pushToDrawDownSink
                )
            }
        }
    }

    // RESTORED: Enhanced position source from Dieter's implementation
    access(all) struct PositionSource: DFB.Source {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) let pool: Capability<auth(EPosition) &Pool>
        access(self) let positionID: UInt64
        access(self) let type: Type
        access(self) let pullFromTopUpSource: Bool

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pullFromTopUpSource: Bool) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pullFromTopUpSource = pullFromTopUpSource
        }

        access(all) view fun getSourceType(): Type {
            return self.type
        }

        access(all) fun minimumAvailable(): UFix64 {
            if !self.pool.check() {
                return 0.0
            }
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.positionID, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if !self.pool.check() {
                return <- DFBUtils.getEmptyVault(self.type)
            }
            let pool = self.pool.borrow()!
            let available = pool.availableBalance(pid: self.positionID, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            if withdrawAmount > 0.0 {
                return <- pool.withdrawAndPull(pid: self.positionID, type: self.type, amount: withdrawAmount, pullFromTopUpSource: self.pullFromTopUpSource)
            } else {
                // Create an empty vault - this is a limitation we need to handle properly
                return <- DFBUtils.getEmptyVault(self.type)
            }
        }
    }

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

    access(self) view fun borrowPool(): auth(EPosition) &Pool {
        return self.account.storage.borrow<auth(EPosition) &Pool>(from: self.PoolStoragePath)
            ?? panic("Could not borrow reference to internal TidalProtocol Pool resource")
    }

    access(self) view fun borrowMOETMinter(): &MOET.Minter {
        return self.account.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to internal MOET Minter resource")
    }

    init() {
        self.PoolStoragePath = StoragePath(identifier: "tidalProtocolPool_\(self.account.address)")!
        self.PoolFactoryPath = StoragePath(identifier: "tidalProtocolPoolFactory_\(self.account.address)")!
        self.PoolPublicPath = PublicPath(identifier: "tidalProtocolPool_\(self.account.address)")!

        // save Pool in storage & configure public Capability
        self.account.storage.save(
            <-create PoolFactory(),
            to: self.PoolFactoryPath
        )
        let factory = self.account.storage.borrow<&PoolFactory>(from: self.PoolFactoryPath)!
    }
}
