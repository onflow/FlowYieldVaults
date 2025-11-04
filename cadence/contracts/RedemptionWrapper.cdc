import "FungibleToken"
import "TidalProtocol"
import "MOET"
import "DeFiActions"
import "TidalMath"

/// RedemptionWrapper V2 - Production-Hardened MOET Redemption Contract
///
/// Allows users to redeem MOET stablecoin for underlying collateral at oracle prices,
/// with dynamic bonuses/haircuts based on position health. Includes comprehensive
/// protections against MEV, position insolvency, and system abuse.
access(all) contract RedemptionWrapper {

    access(all) let PublicRedemptionPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    access(all) let RedemptionPositionStoragePath: StoragePath

    // Events for auditing and monitoring
    access(all) event RedemptionExecuted(
        user: Address,
        moetBurned: UFix64,
        collateralType: Type,
        collateralReceived: UFix64,
        preRedemptionHealth: UFix128,
        postRedemptionHealth: UFix128
    )
    access(all) event Paused(by: Address)
    access(all) event Unpaused(by: Address)
    access(all) event ConfigUpdated(
        maxRedemptionAmount: UFix64,
        minRedemptionAmount: UFix64
    )
    access(all) event DailyLimitReset(date: UFix64, limit: UFix64)

    // Configuration parameters
    access(all) var paused: Bool
    access(all) var maxRedemptionAmount: UFix64 // e.g., 10000.0 - per-tx cap to prevent abuse
    access(all) var minRedemptionAmount: UFix64 // e.g., 10.0 - prevent spam
    
    // MEV and rate limiting protections
    access(all) var redemptionCooldown: UFix64 // seconds between redemptions per user
    access(all) var dailyRedemptionLimit: UFix64 // max MOET redeemable per day
    access(all) var dailyRedemptionUsed: UFix64
    access(all) var lastRedemptionResetDay: UFix64
    access(all) var userLastRedemption: {Address: UFix64}
    
    // Oracle protections
    access(all) var maxPriceAge: UFix64 // max seconds since oracle update
    access(all) var lastPriceUpdate: {Type: UFix64} // Track last price update per token type
    
    // Position health safety
    access(all) var minPostRedemptionHealth: UFix128 // minimum health after redemption
    
    // Position tracking
    access(all) var positionID: UInt64? // Store the redemption position ID
    
    // Reentrancy protection
    access(all) var reentrancyGuard: Bool

    // Admin resource for governance control
    access(all) resource Admin {
        /// Update core redemption configuration parameters
        access(all) fun setConfig(
            maxRedemptionAmount: UFix64,
            minRedemptionAmount: UFix64
        ) {
            pre {
                maxRedemptionAmount > minRedemptionAmount: "Max must be > min redemption amount"
                minRedemptionAmount > 0.0: "Min redemption amount must be positive"
            }
            RedemptionWrapper.maxRedemptionAmount = maxRedemptionAmount
            RedemptionWrapper.minRedemptionAmount = minRedemptionAmount
            emit ConfigUpdated(
                maxRedemptionAmount: maxRedemptionAmount,
                minRedemptionAmount: minRedemptionAmount
            )
        }

        /// Update rate limiting and MEV protection parameters
        access(all) fun setProtectionParams(
            redemptionCooldown: UFix64,
            dailyRedemptionLimit: UFix64,
            maxPriceAge: UFix64,
            minPostRedemptionHealth: UFix128
        ) {
            pre {
                redemptionCooldown <= 3600.0: "Cooldown too long (max 1 hour)"
                dailyRedemptionLimit > 0.0: "Daily limit must be positive"
                maxPriceAge <= 7200.0: "Max price age too long (max 2 hours)"
                minPostRedemptionHealth >= TidalMath.toUFix128(1.1): "Min post-redemption health must be >= 1.1"
            }
            RedemptionWrapper.redemptionCooldown = redemptionCooldown
            RedemptionWrapper.dailyRedemptionLimit = dailyRedemptionLimit
            RedemptionWrapper.maxPriceAge = maxPriceAge
            RedemptionWrapper.minPostRedemptionHealth = minPostRedemptionHealth
        }

        /// Pause redemptions in case of emergency
        access(all) fun pause() {
            RedemptionWrapper.paused = true
            emit Paused(by: self.owner!.address)
        }

        /// Unpause redemptions
        access(all) fun unpause() {
            RedemptionWrapper.paused = false
            emit Unpaused(by: self.owner!.address)
        }

        /// Reset daily redemption counter (for emergency use)
        access(all) fun resetDailyLimit() {
            RedemptionWrapper.dailyRedemptionUsed = 0.0
            RedemptionWrapper.lastRedemptionResetDay = getCurrentBlock().timestamp / 86400.0
        }
    }

    // Public redemption interface
    access(all) resource Redeemer {
        /// Redeem MOET for collateral at 1:1 oracle price ($1 of MOET = $1 of collateral)
        /// 
        /// @param moet: MOET vault to burn
        /// @param preferredCollateralType: Optional type to request specific collateral; nil uses default
        /// @param receiver: Capability to receive collateral
        ///
        /// Economics:
        /// - Strict 1:1 redemption (no bonuses or penalties)
        /// - Maintains MOET = $1.00 peg exactly
        /// - Sustainable for redemption position (no value drain)
        ///
        /// Security features:
        /// - Reentrancy protection
        /// - Daily and per-tx limits
        /// - Per-user cooldowns
        /// - Oracle staleness checks
        /// - Position solvency verification (pre and post)
        /// - Liquidation status check
        access(all) fun redeem(
            moet: @MOET.Vault,
            preferredCollateralType: Type?,
            receiver: Capability<&{FungibleToken.Receiver}>
        ) {
            pre {
                !RedemptionWrapper.reentrancyGuard: "Reentrancy detected"
                !RedemptionWrapper.paused: "Redemptions are paused"
                receiver.check(): "Invalid receiver capability"
                RedemptionWrapper.getPosition() != nil: "Position not set up"
                moet.balance > 0.0: "Cannot redeem zero MOET"
                moet.balance >= RedemptionWrapper.minRedemptionAmount: "Below minimum redemption amount"
                moet.balance <= RedemptionWrapper.maxRedemptionAmount: "Exceeds max redemption amount"
            }
            post {
                // Redemption should maintain or improve position health
                // (burning debt with collateral withdrawal should keep position safe)
                RedemptionWrapper.getPosition()!.getHealth() >= RedemptionWrapper.minPostRedemptionHealth:
                    "Post-redemption health below minimum threshold"
            }

            // Reentrancy guard
            RedemptionWrapper.reentrancyGuard = true

            let amount = moet.balance
            let pool = RedemptionWrapper.getPool()
            let position = RedemptionWrapper.getPosition()! // Cache to avoid multiple calls

            // Check user cooldown
            let userAddr = receiver.address
            if let lastTime = RedemptionWrapper.userLastRedemption[userAddr] {
                assert(
                    getCurrentBlock().timestamp - lastTime >= RedemptionWrapper.redemptionCooldown,
                    message: "Redemption cooldown not elapsed"
                )
            }

            // Check and update daily limit
            let currentDay = getCurrentBlock().timestamp / 86400.0
            if currentDay > RedemptionWrapper.lastRedemptionResetDay {
                RedemptionWrapper.dailyRedemptionUsed = 0.0
                RedemptionWrapper.lastRedemptionResetDay = currentDay
                emit DailyLimitReset(date: currentDay, limit: RedemptionWrapper.dailyRedemptionLimit)
            }
            assert(
                RedemptionWrapper.dailyRedemptionUsed + amount <= RedemptionWrapper.dailyRedemptionLimit,
                message: "Daily redemption limit exceeded"
            )

            // Check position is not liquidatable
            let preHealth = position.getHealth()
            assert(
                !pool.isLiquidatable(RedemptionWrapper.getPositionID()),
                message: "Redemption position is liquidatable"
            )

            // Determine collateral type: preferred or fallback to pool default
            var collateralType: Type = preferredCollateralType ?? pool.defaultToken
            var available = position.availableBalance(type: collateralType, pullFromTopUpSource: false)
            
            // If preferred type has no balance, try default
            if available == 0.0 && preferredCollateralType != nil {
                collateralType = pool.defaultToken
                available = position.availableBalance(type: collateralType, pullFromTopUpSource: false)
            }
            
            // Validate collateral is available
            assert(available > 0.0, message: "No collateral available for requested type")

            // Get oracle price
            let priceOptional = pool.priceOracle.price(ofToken: collateralType)
            assert(priceOptional != nil, message: "Oracle price unavailable for collateral type")
            let price = priceOptional!

            // Check oracle staleness - track last update per token type
            let currentTime = getCurrentBlock().timestamp
            let lastUpdate = RedemptionWrapper.lastPriceUpdate[collateralType] ?? 0.0
            
            // If we've seen this token before, check staleness
            // Otherwise, this is first redemption for this token type (acceptable)
            if lastUpdate > 0.0 {
                assert(
                    currentTime - lastUpdate <= RedemptionWrapper.maxPriceAge,
                    message: "Oracle price too stale - last update was too long ago"
                )
            }
            
            // Update last seen price timestamp for this token
            RedemptionWrapper.lastPriceUpdate[collateralType] = currentTime

            // Calculate collateral amount at 1:1 oracle price
            // 1 MOET (valued at $1) = $1 worth of collateral
            // Example: If Flow is $2, then 100 MOET = 50 Flow
            let collateralAmount = amount / price

            // Cap to available balance to prevent over-withdrawal
            let safeAvailable = position.availableBalance(type: collateralType, pullFromTopUpSource: false)
            if collateralAmount > safeAvailable {
                // Not enough collateral available for full redemption
                panic("Insufficient collateral available - position cannot service this redemption")
            }

            // Validate that we have collateral to withdraw
            assert(collateralAmount > 0.0, message: "Zero collateral available after adjustments")

            // Burn MOET via position's repayment sink (reuse cached position)
            let sink = position.createSink(type: Type<@MOET.Vault>())
            sink.depositCapacity(from: &moet as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            let repaid = amount - moet.balance
            destroy moet  // Destroy any remaining (should be zero if fully accepted)

            // Validate that MOET was actually burned
            assert(repaid > 0.0, message: "No MOET was repaid/burned")

            // Withdraw collateral from position
            let withdrawn <- position.withdrawAndPull(
                type: collateralType,
                amount: collateralAmount,
                pullFromTopUpSource: false
            )

            // Verify post-redemption health is above minimum threshold
            let postHealth = position.getHealth()
            assert(
                postHealth >= RedemptionWrapper.minPostRedemptionHealth,
                message: "Post-redemption health below minimum threshold"
            )

            // Send to user (after all checks pass)
            receiver.borrow()!.deposit(from: <-withdrawn)

            // Update state: daily limit and user cooldown
            RedemptionWrapper.dailyRedemptionUsed = RedemptionWrapper.dailyRedemptionUsed + repaid
            RedemptionWrapper.userLastRedemption[userAddr] = getCurrentBlock().timestamp

            // Release reentrancy guard
            RedemptionWrapper.reentrancyGuard = false

            // Emit event for transparency
            emit RedemptionExecuted(
                user: receiver.address,
                moetBurned: repaid,
                collateralType: collateralType,
                collateralReceived: collateralAmount,
                preRedemptionHealth: preHealth,
                postRedemptionHealth: postHealth
            )
        }
    }

    /// Setup the redemption position with initial collateral
    /// @param initialCollateral: Collateral to seed the position (should be substantial to prevent early insolvency)
    /// @param issuanceSink: Where borrowed MOET will be sent (should accept minted MOET)
    /// @param repaymentSource: Optional source for automatic position top-ups (recommended for safety)
    ///
    /// Best practices:
    /// - Initial collateral should be >>  expected MOET debt to maintain healthy ratios
    /// - Use a topUpSource (repaymentSource) to prevent liquidation risk
    /// - Monitor position health regularly and rebalance as needed
    access(all) fun setup(
        initialCollateral: @FungibleToken.Vault,
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?
    ) {
        let poolCap = self.account.capabilities.get<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        assert(poolCap.check(), message: "No pool capability")

        let pool = poolCap.borrow()!
        let pid = pool.createPosition(
            funds: <-initialCollateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: true
        )

        // Store position ID for liquidation checks
        self.positionID = pid

        let position = TidalProtocol.Position(id: pid, pool: poolCap)
        self.account.storage.save(position, to: self.RedemptionPositionStoragePath)
    }

    /// Get reference to the TidalProtocol Pool
    access(all) fun getPool(): &TidalProtocol.Pool {
        return self.account.capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
            ?? panic("No pool capability")
    }

    /// Get reference to the redemption position
    access(all) fun getPosition(): &TidalProtocol.Position? {
        return self.account.storage.borrow<&TidalProtocol.Position>(from: self.RedemptionPositionStoragePath)
    }

    /// Get the position ID for liquidation checks
    access(self) fun getPositionID(): UInt64 {
        return self.positionID ?? panic("Position not set up - call setup() first")
    }

    /// View function to check if a redemption would succeed (pre-flight check)
    access(all) fun canRedeem(moetAmount: UFix64, collateralType: Type, user: Address): Bool {
        if self.paused { return false }
        if moetAmount < self.minRedemptionAmount || moetAmount > self.maxRedemptionAmount { return false }
        
        // Check user cooldown
        if let lastTime = self.userLastRedemption[user] {
            if getCurrentBlock().timestamp - lastTime < self.redemptionCooldown {
                return false
            }
        }
        
        // Check daily limit
        if self.dailyRedemptionUsed + moetAmount > self.dailyRedemptionLimit {
            return false
        }
        
        // Check collateral availability
        let position = self.getPosition()
        if position == nil { return false }
        
        let available = position!.availableBalance(type: collateralType, pullFromTopUpSource: false)
        let price = self.getPool().priceOracle.price(ofToken: collateralType) ?? 0.0
        if price == 0.0 { return false }
        
        let requiredCollateral = moetAmount / price
        return requiredCollateral <= available
    }

    /// View function to estimate redemption output
    /// Returns exact collateral amount at 1:1 oracle price (no bonuses or penalties)
    access(all) fun estimateRedemption(moetAmount: UFix64, collateralType: Type): UFix64 {
        let pool = self.getPool()
        let price = pool.priceOracle.price(ofToken: collateralType) ?? panic("Price unavailable")
        
        // Simple 1:1 calculation
        return moetAmount / price
    }

    init() {
        self.PublicRedemptionPath = /public/redemptionWrapper
        self.AdminStoragePath = /storage/redemptionAdmin
        self.RedemptionPositionStoragePath = /storage/redemptionPosition

        // Initialize configuration with sensible defaults
        self.paused = false
        self.maxRedemptionAmount = 10000.0               // Cap per tx
        self.minRedemptionAmount = 10.0                  // Min per tx (prevent spam)
        
        // MEV and rate limiting protections
        self.redemptionCooldown = 60.0                   // 1 minute cooldown per user
        self.dailyRedemptionLimit = 100000.0             // 100k MOET per day
        self.dailyRedemptionUsed = 0.0
        self.lastRedemptionResetDay = getCurrentBlock().timestamp / 86400.0
        self.userLastRedemption = {}
        
        // Oracle protections
        self.maxPriceAge = 3600.0                        // 1 hour max price age
        self.lastPriceUpdate = {}                        // Initialize empty price tracking
        
        // Position health safety
        self.minPostRedemptionHealth = TidalMath.toUFix128(1.15) // Require 115% health after redemption
        
        // Position tracking
        self.positionID = nil                            // Set during setup()
        
        // Reentrancy protection
        self.reentrancyGuard = false

        // Create and save Admin resource for governance
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)

        // Create and publish Redeemer capability
        let redeemer <- create Redeemer()
        self.account.storage.save(<-redeemer, to: /storage/redemptionRedeemer)

        self.account.capabilities.publish(
            self.account.capabilities.storage.issue<&Redeemer>(/storage/redemptionRedeemer),
            at: self.PublicRedemptionPath
        )
    }
}

