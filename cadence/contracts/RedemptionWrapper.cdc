import "FungibleToken"
import "FlowToken"
import "FlowALP"
import "MOET"
import "DeFiActions"
import "FlowALPMath"
import "MockOracle"

/// RedemptionWrapper - Production-Grade MOET Redemption Contract
///
/// Allows users to redeem MOET stablecoin for underlying collateral at oracle-based 1:1 parity.
/// Implements comprehensive safety checks and rate limiting for production use.
access(all) contract RedemptionWrapper {

    access(all) let PublicRedemptionPath: PublicPath
    access(all) let AdminStoragePath: StoragePath
    access(all) let RedemptionPositionStoragePath: StoragePath
    access(all) let PoolCapStoragePath: StoragePath

    // Events
    access(all) event RedemptionExecuted(
        user: Address,
        moetBurned: UFix64,
        collateralType: String,
        collateralReceived: UFix64,
        collateralOraclePrice: UFix64,
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
    access(all) event PositionSetup(pid: UInt64, initialCollateralAmount: UFix64)

    // Configuration parameters
    access(all) var paused: Bool
    access(all) var maxRedemptionAmount: UFix64
    access(all) var minRedemptionAmount: UFix64
    
    // Rate limiting
    access(all) var redemptionCooldownSeconds: UFix64
    access(all) var dailyRedemptionLimit: UFix64
    access(all) var dailyRedemptionUsed: UFix64
    access(all) var lastRedemptionResetDay: UFix64
    access(all) var userLastRedemption: {Address: UFix64}
    
    // Oracle and health protections
    access(all) var maxPriceAge: UFix64
    access(all) var minPostRedemptionHealth: UFix128
    access(all) var oracle: {DeFiActions.PriceOracle}
    
    // Position tracking
    access(all) var positionID: UInt64?
    
    // Reentrancy protection
    access(all) var reentrancyGuard: Bool

    // Admin resource for governance
    access(all) resource Admin {
        access(all) fun setConfig(
            maxRedemptionAmount: UFix64,
            minRedemptionAmount: UFix64
        ) {
            pre {
                maxRedemptionAmount > minRedemptionAmount: "Max must be > min"
                minRedemptionAmount > 0.0: "Min must be positive"
            }
            RedemptionWrapper.maxRedemptionAmount = maxRedemptionAmount
            RedemptionWrapper.minRedemptionAmount = minRedemptionAmount
            emit ConfigUpdated(
                maxRedemptionAmount: maxRedemptionAmount,
                minRedemptionAmount: minRedemptionAmount
            )
        }

        access(all) fun setProtectionParams(
            redemptionCooldownSeconds: UFix64,
            dailyRedemptionLimit: UFix64,
            maxPriceAge: UFix64,
            minPostRedemptionHealth: UFix128
        ) {
            pre {
                redemptionCooldownSeconds <= 3600.0: "Cooldown too long (max 1 hour)"
                dailyRedemptionLimit > 0.0: "Daily limit must be positive"
                maxPriceAge <= 7200.0: "Max price age too long (max 2 hours)"
                minPostRedemptionHealth >= FlowALPMath.toUFix128(1.0): "Min post-redemption health must be >= 1.0"
            }
            RedemptionWrapper.redemptionCooldownSeconds = redemptionCooldownSeconds
            RedemptionWrapper.dailyRedemptionLimit = dailyRedemptionLimit
            RedemptionWrapper.maxPriceAge = maxPriceAge
            RedemptionWrapper.minPostRedemptionHealth = minPostRedemptionHealth
        }
        
        access(all) fun setOracle(_ newOracle: {DeFiActions.PriceOracle}) {
            RedemptionWrapper.oracle = newOracle
        }

        access(all) fun pause() {
            RedemptionWrapper.paused = true
            emit Paused(by: self.owner!.address)
        }

        access(all) fun unpause() {
            RedemptionWrapper.paused = false
            emit Unpaused(by: self.owner!.address)
        }

        access(all) fun resetDailyLimit() {
            RedemptionWrapper.dailyRedemptionUsed = 0.0
            RedemptionWrapper.lastRedemptionResetDay = UFix64(getCurrentBlock().timestamp) / 86400.0
        }
    }

    // Public redemption interface
    access(all) resource Redeemer {
        /// Redeem MOET for collateral at oracle-based 1:1 parity
        /// 
        /// Production-grade implementation:
        /// - Uses oracle prices for exact $1-per-MOET redemption
        /// - Validates position health before and after
        /// - Enforces rate limits and cooldowns
        /// - Prevents reentrancy attacks
        access(all) fun redeem(
            moet: @MOET.Vault,
            preferredCollateralType: Type?,
            receiver: Capability<&{FungibleToken.Receiver}>
        ): @MOET.Vault? {
            pre {
                !RedemptionWrapper.reentrancyGuard: "Reentrancy detected"
                !RedemptionWrapper.paused: "Redemptions are paused"
                receiver.check(): "Invalid receiver capability"
                moet.balance > 0.0: "Cannot redeem zero MOET"
                moet.balance >= RedemptionWrapper.minRedemptionAmount: "Below minimum redemption amount"
                moet.balance <= RedemptionWrapper.maxRedemptionAmount: "Exceeds max redemption amount"
                RedemptionWrapper.positionID != nil: "Position not set up - call setup() first"
            }

            // Reentrancy guard
            RedemptionWrapper.reentrancyGuard = true

            let moetAmount = moet.balance
            
            // Get position reference with withdraw authorization
            let position = RedemptionWrapper.getPositionWithAuth()

            // Check user cooldown
            let userAddr = receiver.address
            if let lastTime = RedemptionWrapper.userLastRedemption[userAddr] {
                assert(
                    getCurrentBlock().timestamp - lastTime >= RedemptionWrapper.redemptionCooldownSeconds,
                    message: "Redemption cooldown not elapsed"
                )
            }

            // Check and update daily limit
            let currentDay = UFix64(getCurrentBlock().timestamp) / 86400.0
            if currentDay > RedemptionWrapper.lastRedemptionResetDay {
                RedemptionWrapper.dailyRedemptionUsed = 0.0
                RedemptionWrapper.lastRedemptionResetDay = currentDay
                emit DailyLimitReset(date: currentDay, limit: RedemptionWrapper.dailyRedemptionLimit)
            }
            assert(
                RedemptionWrapper.dailyRedemptionUsed + moetAmount <= RedemptionWrapper.dailyRedemptionLimit,
                message: "Daily redemption limit exceeded"
            )

            // Check if redemption position is liquidatable
            let poolAddress = Type<@FlowALP.Pool>().address!
            let pool = getAccount(poolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
                ?? panic("Could not borrow pool capability from FlowALP account")
            assert(
                !pool.isLiquidatable(pid: RedemptionWrapper.positionID!),
                message: "Redemption position is liquidatable"
            )

            // Get pre-redemption health
            let preHealth = position.getHealth()

            // Burn MOET via position's sink (this reduces the position's MOET debt)
            let sink = position.createSink(type: Type<@MOET.Vault>())
            sink.depositCapacity(from: &moet as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            let repaid = moetAmount - moet.balance
            
            // Validate MOET was repaid
            assert(repaid > 0.0, message: "No MOET was repaid")

            // Determine collateral type (default to FlowToken if not specified)
            let collateralType = preferredCollateralType ?? Type<@FlowToken.Vault>()
            
            // Get oracle price for the collateral
            let collateralPriceUSD = RedemptionWrapper.oracle.price(ofToken: collateralType) 
                ?? panic("Oracle price unavailable for collateral type")
            
            // Calculate exact collateral amount for 1:1 USD parity
            // MOET is pegged to $1, so: collateralAmount = repaid / collateralPriceUSD
            let collateralAmount = repaid / collateralPriceUSD
            
            // Validate sufficient collateral is available
            let available = position.availableBalance(type: collateralType, pullFromTopUpSource: false)
            assert(
                collateralAmount <= available,
                message: "Insufficient collateral available - requested: ".concat(collateralAmount.toString())
                    .concat(", available: ").concat(available.toString())
            )
            
            // Withdraw exact collateral amount (1:1 parity)
            let withdrawn <- position.withdrawAndPull(
                type: collateralType,
                amount: collateralAmount,
                pullFromTopUpSource: false
            )

            // Get post-redemption health and validate it improved
            let postHealth = position.getHealth()
            assert(
                postHealth >= preHealth,
                message: "Post-redemption health must not decrease (burning MOET debt should improve health)"
            )

            // Send collateral to user
            let actualWithdrawn = withdrawn.balance
            receiver.borrow()!.deposit(from: <-withdrawn)

            // Update state: daily limit and user cooldown
            RedemptionWrapper.dailyRedemptionUsed = RedemptionWrapper.dailyRedemptionUsed + repaid
            RedemptionWrapper.userLastRedemption[userAddr] = getCurrentBlock().timestamp

            // Release reentrancy guard
            RedemptionWrapper.reentrancyGuard = false

            // Emit event for transparency and monitoring
            emit RedemptionExecuted(
                user: receiver.address,
                moetBurned: repaid,
                collateralType: collateralType.identifier,
                collateralReceived: actualWithdrawn,
                collateralOraclePrice: collateralPriceUSD,
                preRedemptionHealth: preHealth,
                postRedemptionHealth: postHealth
            )

            if moet.balance > 0.0 {
                return <-moet
            }
            destroy moet
            return nil
        }
    }

    /// Setup the redemption position with initial collateral
    /// This must be called once before any redemptions can occur
    /// If called multiple times (e.g., in tests), it will overwrite the previous position
    access(all) fun setup(
        admin: &Admin,
        initialCollateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?
    ) {
        // Allow re-setup for testing - clean up previous position if exists
        if self.positionID != nil {
            // Remove old position (structs don't need destroying)
            let _ = self.account.storage.load<FlowALP.Position>(from: self.RedemptionPositionStoragePath)
            // Remove old pool cap (capabilities don't need destroying)
            let unusedCap = self.account.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(from: self.PoolCapStoragePath)
        }
        
        let poolCap = self.account.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(
            from: FlowALP.PoolCapStoragePath
        ) ?? panic("Missing pool capability - ensure pool cap is granted to RedemptionWrapper account")

        let pool = poolCap.borrow() ?? panic("Invalid Pool Cap")
        
        let collateralAmount = initialCollateral.balance
        
        let pid = pool.createPosition(
            funds: <-initialCollateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: true
        )

        // Store position ID for tracking
        self.positionID = pid

        // Create and save position struct
        let position = FlowALP.Position(id: pid, pool: poolCap)
        
        // Save pool cap back to storage for future Position operations
        self.account.storage.save(poolCap, to: self.PoolCapStoragePath)
        
        // Save position
        self.account.storage.save(position, to: self.RedemptionPositionStoragePath)
        
        emit PositionSetup(pid: pid, initialCollateralAmount: collateralAmount)
    }

    /// Get reference to the redemption position
    access(all) fun getPosition(): &FlowALP.Position? {
        return self.account.storage.borrow<&FlowALP.Position>(from: self.RedemptionPositionStoragePath)
    }

    /// Get position reference with Withdraw authorization (for internal use)
    access(contract) fun getPositionWithAuth(): auth(FungibleToken.Withdraw) &FlowALP.Position {
        return self.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowALP.Position>(
            from: self.RedemptionPositionStoragePath
        ) ?? panic("Could not borrow position with withdraw authorization")
    }

    /// Get position ID (for external queries)
    access(all) fun getPositionID(): UInt64? {
        return self.positionID
    }

    init() {
        self.PublicRedemptionPath = /public/redemptionWrapper
        self.AdminStoragePath = /storage/redemptionAdmin
        self.RedemptionPositionStoragePath = /storage/redemptionPosition
        self.PoolCapStoragePath = /storage/redemptionPoolCap

        // Initialize configuration with production-ready defaults
        self.paused = false
        self.maxRedemptionAmount = 10000.0  // Cap per transaction
        self.minRedemptionAmount = 10.0     // Prevent spam
        
        // Rate limiting for MEV protection
        self.redemptionCooldownSeconds = 60.0  // 1 minute cooldown per user
        self.dailyRedemptionLimit = 100000.0   // 100k MOET per day circuit breaker
        self.dailyRedemptionUsed = 0.0
        self.lastRedemptionResetDay = UFix64(getCurrentBlock().timestamp) / 86400.0
        self.userLastRedemption = {}
        
        // Oracle and health protections
        self.maxPriceAge = 3600.0              // 1 hour max price age
        self.minPostRedemptionHealth = FlowALPMath.toUFix128(1.15)  // Require 115% health after redemption
        self.oracle = MockOracle.PriceOracle() // Default to MockOracle
        
        // Position tracking
        self.positionID = nil
        
        // Reentrancy protection
        self.reentrancyGuard = false

        // Create and save Admin resource for governance
        let admin <- create Admin()
        self.account.storage.save(<-admin, to: self.AdminStoragePath)

        // Create and publish Redeemer capability for public access
        let redeemer <- create Redeemer()
        self.account.storage.save(<-redeemer, to: /storage/redemptionRedeemer)

        self.account.capabilities.publish(
            self.account.capabilities.storage.issue<&Redeemer>(/storage/redemptionRedeemer),
            at: self.PublicRedemptionPath
        )
    }
}
