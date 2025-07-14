import "Tidal"
import "TidalYieldAutoBalancers"
import "MockOracle"
import "YieldToken"
import "MOET"
import "FlowToken"

access(all) struct CompletePositionInfo {
    access(all) let tideId: UInt64                        // Unique identifier for the tide/position
    access(all) let collateralInfo: CollateralInfo        // Contains yield token balance (misnamed for API compatibility)
    access(all) let yieldTokenInfo: YieldTokenInfo        // Yield token details and values
    access(all) let debtInfo: DebtInfo                    // Estimated borrowed MOET debt information
    access(all) let healthMetrics: HealthMetrics          // Position health ratios and risk metrics
    
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

access(all) struct CollateralInfo {
    access(all) let collateralType: String
    access(all) let availableBalance: UFix64  // NOTE: This is actually yield token balance from auto balancer, not collateral tokens
    access(all) let collateralValue: UFix64   // USD value of the yield tokens (treating them as collateral for health calc)
    access(all) let collateralPrice: UFix64   // Price used for valuation (Flow price, not yield token price)
    access(all) let supportedTypes: [String]  // Array of supported collateral token type identifiers
    
    init(collateralType: String, availableBalance: UFix64, collateralValue: UFix64, collateralPrice: UFix64, supportedTypes: [String]) {
        self.collateralType = collateralType
        self.availableBalance = availableBalance  // Passing yield token balance as availableBalance for API compatibility
        self.collateralValue = collateralValue
        self.collateralPrice = collateralPrice
        self.supportedTypes = supportedTypes
    }
}

access(all) struct YieldTokenInfo {
    access(all) let yieldTokenBalance: UFix64        // Balance of yield tokens held in auto balancer
    access(all) let yieldTokenValue: UFix64          // USD value of yield tokens (balance * price)
    access(all) let yieldTokenPrice: UFix64          // Current price of yield tokens
    access(all) let yieldTokenIdentifier: String     // Type identifier for yield token contract
    access(all) let isActive: Bool                   // Whether auto balancer is active/exists
    
    init(yieldTokenBalance: UFix64, yieldTokenValue: UFix64, yieldTokenPrice: UFix64, yieldTokenIdentifier: String, isActive: Bool) {
        self.yieldTokenBalance = yieldTokenBalance
        self.yieldTokenValue = yieldTokenValue
        self.yieldTokenPrice = yieldTokenPrice
        self.yieldTokenIdentifier = yieldTokenIdentifier
        self.isActive = isActive
    }
}

access(all) struct DebtInfo {
    access(all) let estimatedMoetDebt: UFix64        // Estimated amount of MOET tokens borrowed
    access(all) let estimatedDebtValue: UFix64       // USD value of estimated debt
    access(all) let moetPrice: UFix64                // Current price of MOET tokens
    access(all) let loanTokenIdentifier: String      // Type identifier for loan token (MOET)
    
    init(estimatedMoetDebt: UFix64, estimatedDebtValue: UFix64, moetPrice: UFix64, loanTokenIdentifier: String) {
        self.estimatedMoetDebt = estimatedMoetDebt
        self.estimatedDebtValue = estimatedDebtValue
        self.moetPrice = moetPrice
        self.loanTokenIdentifier = loanTokenIdentifier
    }
}

access(all) struct HealthMetrics {
    access(all) let realAvailableBalance: UFix64         // Yield token balance from auto balancer (same as availableBalance above)
    access(all) let estimatedCollateralValue: UFix64     // USD value of yield tokens treated as collateral
    access(all) let liquidationRiskThreshold: UFix64     // DANGER: Below this risks liquidation (hardcoded to 1.1)
    access(all) let autoRebalanceThreshold: UFix64       // AUTO: Triggers rebalancing (hardcoded to 1.1)
    access(all) let optimalHealthRatio: UFix64           // TARGET: Ideal health ratio (hardcoded to 1.3)
    access(all) let maxEfficiencyThreshold: UFix64       // MAX: Upper limit for efficiency (hardcoded to 1.5)
    access(all) let netWorth: UFix64                     // Total value minus debt (collateral + yield - debt)
    access(all) let leverageRatio: UFix64                // Total position value / collateral value
    access(all) let yieldTokenRatio: UFix64              // Actual yield token value / expected yield token value
    access(all) let estimatedHealth: UFix64              // Effective collateral / debt ratio (with 0.8 collateral factor)
    
    init(
        realAvailableBalance: UFix64,
        estimatedCollateralValue: UFix64,
        netWorth: UFix64,
        leverageRatio: UFix64,
        yieldTokenRatio: UFix64,
        estimatedHealth: UFix64
    ) {
        self.realAvailableBalance = realAvailableBalance
        self.estimatedCollateralValue = estimatedCollateralValue
        self.liquidationRiskThreshold = 1.1    // DANGER: Below this risks liquidation
        self.autoRebalanceThreshold = 1.1      // AUTO: Triggers rebalancing
        self.optimalHealthRatio = 1.3          // TARGET: Ideal health ratio
        self.maxEfficiencyThreshold = 1.5      // MAX: Upper limit for efficiency
        self.netWorth = netWorth
        self.leverageRatio = leverageRatio
        self.yieldTokenRatio = yieldTokenRatio
        self.estimatedHealth = estimatedHealth
    }
}

access(all) struct CompleteUserSummary {
    access(all) let userAddress: Address                 // User's Flow address
    access(all) let totalPositions: Int                  // Number of tide positions
    access(all) let portfolioSummary: PortfolioSummary   // Aggregated portfolio metrics
    access(all) let positions: [CompletePositionInfo]    // Array of individual position details
    access(all) let timestamp: UFix64                    // Block timestamp when data was retrieved
    
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

access(all) struct PortfolioSummary {
    access(all) let totalCollateralValue: UFix64         // Sum of all yield token balances (misnamed for API compatibility)
    access(all) let totalYieldTokenValue: UFix64         // Sum of all yield token USD values
    access(all) let totalEstimatedDebtValue: UFix64      // Sum of all estimated MOET debt values
    access(all) let totalNetWorth: UFix64                // Total portfolio value minus debt
    access(all) let averageLeverageRatio: UFix64         // Average leverage across all positions
    access(all) let portfolioHealthRatio: UFix64         // Average yield token ratio across all positions
    
    init(
        totalCollateralValue: UFix64,
        totalYieldTokenValue: UFix64,
        totalEstimatedDebtValue: UFix64,
        totalNetWorth: UFix64,
        averageLeverageRatio: UFix64,
        portfolioHealthRatio: UFix64
    ) {
        self.totalCollateralValue = totalCollateralValue
        self.totalYieldTokenValue = totalYieldTokenValue
        self.totalEstimatedDebtValue = totalEstimatedDebtValue
        self.totalNetWorth = totalNetWorth
        self.averageLeverageRatio = averageLeverageRatio
        self.portfolioHealthRatio = portfolioHealthRatio
    }
}

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
                portfolioHealthRatio: 0.0
            ),
            positions: []
        )
    }
    
    let tideIds = tideManager!.getIDs()
    let positions: [CompletePositionInfo] = []
    
    let oracle = MockOracle.PriceOracle()
    let yieldTokenPrice = oracle.price(ofToken: Type<@YieldToken.Vault>()) ?? 2.0
    let moetPrice = oracle.price(ofToken: Type<@MOET.Vault>()) ?? 1.0
    let flowPrice = oracle.price(ofToken: Type<@FlowToken.Vault>()) ?? 1.0
    
    // Note: TidalProtocol positions and Tidal tides use different ID systems
    // We'll calculate health manually since tide IDs don't correspond to TidalProtocol position IDs
    
    var totalCollateralValue = 0.0
    var totalYieldTokenValue = 0.0
    var totalEstimatedDebtValue = 0.0
    var totalLeverageRatio = 0.0
    var totalYieldTokenRatio = 0.0
    
    for tideId in tideIds {
        if let tide = tideManager!.borrowTide(id: tideId) {
            let autoBalancer = TidalYieldAutoBalancers.borrowAutoBalancer(id: tideId)
            
            // Use TidalProtocol position balance instead of auto balancer balance
            // This should now work if the overflow issue has been fixed
            let realAvailableBalance = tide.getTideBalance()
            let yieldTokenBalance = realAvailableBalance
            
            let yieldTokenIdentifier = Type<@YieldToken.Vault>().identifier
            let yieldTokenValue = yieldTokenBalance * yieldTokenPrice
            let isActive = autoBalancer != nil
            
            let supportedVaultTypes = tide.getSupportedVaultTypes()
            var collateralType = "Unknown"
            let supportedTypes: [String] = []
            
            for vaultType in supportedVaultTypes.keys {
                if supportedVaultTypes[vaultType]! {
                    supportedTypes.append(vaultType.identifier)
                    if collateralType == "Unknown" {
                        collateralType = vaultType.identifier
                    }
                }
            }
            
            let estimatedCollateralValue = realAvailableBalance * flowPrice
            let estimatedMoetDebt = yieldTokenBalance * yieldTokenPrice / moetPrice
            let estimatedDebtValue = estimatedMoetDebt * moetPrice
            let loanTokenIdentifier = Type<@MOET.Vault>().identifier
            
            let expectedYieldTokenValue = estimatedMoetDebt * moetPrice
            let yieldTokenRatio = expectedYieldTokenValue > 0.0 ? 
                yieldTokenValue / expectedYieldTokenValue : 1.0
            
            let totalPositionValue = estimatedCollateralValue + yieldTokenValue
            let estimatedLeverageRatio = estimatedCollateralValue > 0.0 ? 
                totalPositionValue / estimatedCollateralValue : 1.0
            
            let netWorth = estimatedCollateralValue + yieldTokenValue - estimatedDebtValue
            
            // Apply collateral factor to match TidalProtocol health calculation
            // FlowToken collateral factor is 0.8 (80%)
            let flowCollateralFactor = 0.8
            let effectiveCollateral = estimatedCollateralValue * flowCollateralFactor
            
            // Note: Yield tokens may not count as collateral in TidalProtocol health calculation
            // TODO: Replace with tide.getPositionHealth() once contracts are updated
            let estimatedHealth = estimatedDebtValue > 0.0 ? 
                effectiveCollateral / estimatedDebtValue : 999.0
            
            let healthMetrics = HealthMetrics(
                realAvailableBalance: realAvailableBalance,
                estimatedCollateralValue: estimatedCollateralValue,
                netWorth: netWorth,
                leverageRatio: estimatedLeverageRatio,
                yieldTokenRatio: yieldTokenRatio,
                estimatedHealth: estimatedHealth
            )
            
            positions.append(CompletePositionInfo(
                tideId: tideId,
                collateralInfo: CollateralInfo(
                    collateralType: collateralType,
                    availableBalance: realAvailableBalance,  // realAvailableBalance is yield token balance from auto balancer
                    collateralValue: estimatedCollateralValue,
                    collateralPrice: flowPrice,
                    supportedTypes: supportedTypes
                ),
                yieldTokenInfo: YieldTokenInfo(
                    yieldTokenBalance: yieldTokenBalance,
                    yieldTokenValue: yieldTokenValue,
                    yieldTokenPrice: yieldTokenPrice,
                    yieldTokenIdentifier: yieldTokenIdentifier,
                    isActive: isActive
                ),
                debtInfo: DebtInfo(
                    estimatedMoetDebt: estimatedMoetDebt,
                    estimatedDebtValue: estimatedDebtValue,
                    moetPrice: moetPrice,
                    loanTokenIdentifier: loanTokenIdentifier
                ),
                healthMetrics: healthMetrics
            ))
            
            totalCollateralValue = totalCollateralValue + realAvailableBalance
            totalYieldTokenValue = totalYieldTokenValue + yieldTokenValue
            totalEstimatedDebtValue = totalEstimatedDebtValue + estimatedDebtValue
            totalLeverageRatio = totalLeverageRatio + estimatedLeverageRatio
            totalYieldTokenRatio = totalYieldTokenRatio + yieldTokenRatio
        }
    }
    
    let totalNetWorth = totalCollateralValue + totalYieldTokenValue - totalEstimatedDebtValue
    let averageLeverageRatio = tideIds.length > 0 ? totalLeverageRatio / UFix64(tideIds.length) : 0.0
    let portfolioHealthRatio = tideIds.length > 0 ? totalYieldTokenRatio / UFix64(tideIds.length) : 0.0
    
    return CompleteUserSummary(
        userAddress: address,
        totalPositions: tideIds.length,
        portfolioSummary: PortfolioSummary(
            totalCollateralValue: totalCollateralValue,
            totalYieldTokenValue: totalYieldTokenValue,
            totalEstimatedDebtValue: totalEstimatedDebtValue,
            totalNetWorth: totalNetWorth,
            averageLeverageRatio: averageLeverageRatio,
            portfolioHealthRatio: portfolioHealthRatio
        ),
        positions: positions
    )
} 