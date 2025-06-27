import "Tidal"
import "TidalYieldAutoBalancers"
import "MockOracle"
import "YieldToken"
import "MOET"
import "FlowToken"

/// Complete position information for a single Tide
access(all) struct CompletePositionInfo {
    access(all) let tideId: UInt64
    access(all) let collateralInfo: CollateralInfo
    access(all) let yieldTokenInfo: YieldTokenInfo
    access(all) let debtInfo: DebtInfo
    access(all) let healthMetrics: HealthMetrics
    
    init(
        tideId: UInt64,
        collateralInfo: CollateralInfo,
        yieldTokenInfo: YieldTokenInfo,
        debtInfo: DebtInfo,
        healthMetrics: HealthMetrics
    ) {
        self.tideId = tideId
        self.collateralInfo = collateralInfo
        self.yieldTokenInfo = yieldTokenInfo
        self.debtInfo = debtInfo
        self.healthMetrics = healthMetrics
    }
}

/// Collateral (deposit) information
access(all) struct CollateralInfo {
    access(all) let collateralType: String
    access(all) let availableBalance: UFix64  // What user can withdraw
    access(all) let collateralValue: UFix64   // USD value of available collateral
    access(all) let supportedTypes: [String]
    
    init(collateralType: String, availableBalance: UFix64, collateralValue: UFix64, supportedTypes: [String]) {
        self.collateralType = collateralType
        self.availableBalance = availableBalance
        self.collateralValue = collateralValue
        self.supportedTypes = supportedTypes
    }
}

/// Yield token (strategy token) information
access(all) struct YieldTokenInfo {
    access(all) let yieldTokenBalance: UFix64    // Actual YieldToken amount
    access(all) let yieldTokenValue: UFix64      // USD value of YieldTokens
    access(all) let yieldTokenPrice: UFix64      // Current YieldToken price
    access(all) let isActive: Bool               // Whether AutoBalancer exists
    
    init(yieldTokenBalance: UFix64, yieldTokenValue: UFix64, yieldTokenPrice: UFix64, isActive: Bool) {
        self.yieldTokenBalance = yieldTokenBalance
        self.yieldTokenValue = yieldTokenValue
        self.yieldTokenPrice = yieldTokenPrice
        self.isActive = isActive
    }
}

/// Debt (loan) information
access(all) struct DebtInfo {
    access(all) let estimatedMoetDebt: UFix64    // Estimated MOET debt
    access(all) let estimatedDebtValue: UFix64   // USD value of debt
    access(all) let moetPrice: UFix64            // Current MOET price
    access(all) let note: String
    
    init(estimatedMoetDebt: UFix64, estimatedDebtValue: UFix64, moetPrice: UFix64) {
        self.estimatedMoetDebt = estimatedMoetDebt
        self.estimatedDebtValue = estimatedDebtValue
        self.moetPrice = moetPrice
        self.note = "Debt is estimated from YieldToken holdings. For exact debt, use Position ID with get_position_debt.cdc"
    }
}

/// Health and risk metrics
access(all) struct HealthMetrics {
    access(all) let netWorth: UFix64             // Collateral value - debt value
    access(all) let leverageRatio: UFix64        // Total position value / collateral
    access(all) let yieldTokenRatio: UFix64      // YieldToken value / total position value
    access(all) let estimatedHealth: UFix64      // Estimated health ratio
    
    init(netWorth: UFix64, leverageRatio: UFix64, yieldTokenRatio: UFix64, estimatedHealth: UFix64) {
        self.netWorth = netWorth
        self.leverageRatio = leverageRatio
        self.yieldTokenRatio = yieldTokenRatio
        self.estimatedHealth = estimatedHealth
    }
}

/// Complete summary of all user positions
access(all) struct CompleteUserSummary {
    access(all) let userAddress: Address
    access(all) let totalPositions: Int
    access(all) let portfolioSummary: PortfolioSummary
    access(all) let positions: [CompletePositionInfo]
    access(all) let timestamp: UFix64
    
    init(
        userAddress: Address,
        totalPositions: Int,
        portfolioSummary: PortfolioSummary,
        positions: [CompletePositionInfo]
    ) {
        self.userAddress = userAddress
        self.totalPositions = totalPositions
        self.portfolioSummary = portfolioSummary
        self.positions = positions
        self.timestamp = getCurrentBlock().timestamp
    }
}

/// Portfolio-level summary
access(all) struct PortfolioSummary {
    access(all) let totalCollateralValue: UFix64
    access(all) let totalYieldTokenValue: UFix64
    access(all) let totalEstimatedDebtValue: UFix64
    access(all) let totalNetWorth: UFix64
    access(all) let averageLeverageRatio: UFix64
    access(all) let portfolioHealth: String
    
    init(
        totalCollateralValue: UFix64,
        totalYieldTokenValue: UFix64,
        totalEstimatedDebtValue: UFix64,
        totalNetWorth: UFix64,
        averageLeverageRatio: UFix64,
        portfolioHealth: String
    ) {
        self.totalCollateralValue = totalCollateralValue
        self.totalYieldTokenValue = totalYieldTokenValue
        self.totalEstimatedDebtValue = totalEstimatedDebtValue
        self.totalNetWorth = totalNetWorth
        self.averageLeverageRatio = averageLeverageRatio
        self.portfolioHealth = portfolioHealth
    }
}

/// Returns complete position information for all user Tides including:
/// - Collateral balances (deposits available for withdrawal)
/// - Loan balances (estimated debt from YieldToken purchases)  
/// - Yield token balances (strategy tokens purchased with borrowed funds)
/// - Health metrics and portfolio summary
/// 
/// @param address: The user's Flow address
/// @return CompleteUserSummary with all position information
///
/// LIMITATIONS:
/// - Position IDs are private, so debt amounts are estimated from YieldToken holdings
/// - Assumes 1:1 MOET borrowing for YieldToken purchases (typical for TracerStrategy)
/// - For exact debt amounts, track TidalProtocol.Opened events to get Position IDs
///
access(all)
fun main(address: Address): CompleteUserSummary {
    let tideManager = getAccount(address).capabilities.borrow<&Tidal.TideManager>(Tidal.TideManagerPublicPath)
    
    if tideManager == nil {
        return CompleteUserSummary(
            userAddress: address,
            totalPositions: 0,
            portfolioSummary: PortfolioSummary(
                totalCollateralValue: 0.0,
                totalYieldTokenValue: 0.0,
                totalEstimatedDebtValue: 0.0,
                totalNetWorth: 0.0,
                averageLeverageRatio: 0.0,
                portfolioHealth: "No positions"
            ),
            positions: []
        )
    }
    
    let tideIds = tideManager!.getIDs()
    let positions: [CompletePositionInfo] = []
    
    // Get oracle prices with defaults
    let oracle = MockOracle.PriceOracle()
    let yieldTokenPrice = oracle.price(ofToken: Type<@YieldToken.Vault>()) ?? 2.0
    let moetPrice = oracle.price(ofToken: Type<@MOET.Vault>()) ?? 1.0
    let flowPrice = oracle.price(ofToken: Type<@FlowToken.Vault>()) ?? 1.0
    
    // Portfolio totals
    var totalCollateralValue = 0.0
    var totalYieldTokenValue = 0.0
    var totalEstimatedDebtValue = 0.0
    var totalLeverageRatio = 0.0
    
    for tideId in tideIds {
        if let tide = tideManager!.borrowTide(id: tideId) {
            let availableBalance = tide.getTideBalance()
            let supportedVaultTypes = tide.getSupportedVaultTypes()
            
            // Get primary collateral type and value
            var collateralType = "Unknown"
            var collateralValue = 0.0
            let supportedTypes: [String] = []
            
            for vaultType in supportedVaultTypes.keys {
                if supportedVaultTypes[vaultType]! {
                    supportedTypes.append(vaultType.identifier)
                    if collateralType == "Unknown" {
                        collateralType = vaultType.identifier
                        // Estimate collateral value based on available balance and token price
                        if vaultType.identifier.contains("FlowToken") {
                            collateralValue = availableBalance * flowPrice
                        } else if vaultType.identifier.contains("MOET") {
                            collateralValue = availableBalance * moetPrice
                        } else {
                            collateralValue = availableBalance * 1.0 // Default price
                        }
                    }
                }
            }
            
            // Get YieldToken information from AutoBalancer
            let autoBalancer = TidalYieldAutoBalancers.borrowAutoBalancer(id: tideId)
            let yieldTokenBalance = autoBalancer?.vaultBalance() ?? 0.0
            let yieldTokenValue = yieldTokenBalance * yieldTokenPrice
            let isActive = autoBalancer != nil
            
            // Estimate debt (assume 1:1 MOET borrowing for YieldToken purchases)
            let estimatedMoetDebt = yieldTokenBalance * yieldTokenPrice / moetPrice
            let estimatedDebtValue = estimatedMoetDebt * moetPrice
            
            // Calculate health metrics
            let netWorth = collateralValue + yieldTokenValue - estimatedDebtValue
            let totalPositionValue = collateralValue + yieldTokenValue
            let leverageRatio = totalPositionValue > 0.0 ? totalPositionValue / collateralValue : 1.0
            let yieldTokenRatio = totalPositionValue > 0.0 ? yieldTokenValue / totalPositionValue : 0.0
            let estimatedHealth = estimatedDebtValue > 0.0 ? (collateralValue + yieldTokenValue) / estimatedDebtValue : 999.0
            
            // Create position info
            positions.append(CompletePositionInfo(
                tideId: tideId,
                collateralInfo: CollateralInfo(
                    collateralType: collateralType,
                    availableBalance: availableBalance,
                    collateralValue: collateralValue,
                    supportedTypes: supportedTypes
                ),
                yieldTokenInfo: YieldTokenInfo(
                    yieldTokenBalance: yieldTokenBalance,
                    yieldTokenValue: yieldTokenValue,
                    yieldTokenPrice: yieldTokenPrice,
                    isActive: isActive
                ),
                debtInfo: DebtInfo(
                    estimatedMoetDebt: estimatedMoetDebt,
                    estimatedDebtValue: estimatedDebtValue,
                    moetPrice: moetPrice
                ),
                healthMetrics: HealthMetrics(
                    netWorth: netWorth,
                    leverageRatio: leverageRatio,
                    yieldTokenRatio: yieldTokenRatio,
                    estimatedHealth: estimatedHealth
                )
            ))
            
            // Add to portfolio totals
            totalCollateralValue = totalCollateralValue + collateralValue
            totalYieldTokenValue = totalYieldTokenValue + yieldTokenValue
            totalEstimatedDebtValue = totalEstimatedDebtValue + estimatedDebtValue
            totalLeverageRatio = totalLeverageRatio + leverageRatio
        }
    }
    
    // Calculate portfolio summary
    let totalNetWorth = totalCollateralValue + totalYieldTokenValue - totalEstimatedDebtValue
    let averageLeverageRatio = tideIds.length > 0 ? totalLeverageRatio / UFix64(tideIds.length) : 0.0
    let portfolioHealthRatio = totalEstimatedDebtValue > 0.0 ? 
        (totalCollateralValue + totalYieldTokenValue) / totalEstimatedDebtValue : 999.0
    
    var portfolioHealth = "Healthy"
    if portfolioHealthRatio < 1.1 {
        portfolioHealth = "At Risk"
    } else if portfolioHealthRatio < 1.3 {
        portfolioHealth = "Moderate"
    } else if portfolioHealthRatio > 2.0 {
        portfolioHealth = "Very Healthy"
    }
    
    return CompleteUserSummary(
        userAddress: address,
        totalPositions: tideIds.length,
        portfolioSummary: PortfolioSummary(
            totalCollateralValue: totalCollateralValue,
            totalYieldTokenValue: totalYieldTokenValue,
            totalEstimatedDebtValue: totalEstimatedDebtValue,
            totalNetWorth: totalNetWorth,
            averageLeverageRatio: averageLeverageRatio,
            portfolioHealth: portfolioHealth
        ),
        positions: positions
    )
} 