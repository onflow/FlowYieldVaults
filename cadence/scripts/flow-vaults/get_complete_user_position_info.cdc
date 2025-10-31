import "FlowVaults"
import "FlowVaultsAutoBalancers"
import "FlowALP"
import "MockOracle"
import "YieldToken"
import "MOET"
import "FlowToken"

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

access(all) struct CollateralInfo {
    access(all) let collateralType: String
    access(all) let availableBalance: UFix64
    access(all) let collateralValue: UFix64
    access(all) let collateralPrice: UFix64
    access(all) let supportedTypes: [String]
    
    init(collateralType: String, availableBalance: UFix64, collateralValue: UFix64, collateralPrice: UFix64, supportedTypes: [String]) {
        self.collateralType = collateralType
        self.availableBalance = availableBalance
        self.collateralValue = collateralValue
        self.collateralPrice = collateralPrice
        self.supportedTypes = supportedTypes
    }
}

access(all) struct YieldTokenInfo {
    access(all) let yieldTokenBalance: UFix64
    access(all) let yieldTokenValue: UFix64
    access(all) let yieldTokenPrice: UFix64
    access(all) let yieldTokenIdentifier: String
    access(all) let isActive: Bool
    
    init(yieldTokenBalance: UFix64, yieldTokenValue: UFix64, yieldTokenPrice: UFix64, yieldTokenIdentifier: String, isActive: Bool) {
        self.yieldTokenBalance = yieldTokenBalance
        self.yieldTokenValue = yieldTokenValue
        self.yieldTokenPrice = yieldTokenPrice
        self.yieldTokenIdentifier = yieldTokenIdentifier
        self.isActive = isActive
    }
}

access(all) struct DebtInfo {
    access(all) let estimatedMoetDebt: UFix64
    access(all) let estimatedDebtValue: UFix64
    access(all) let moetPrice: UFix64
    access(all) let loanTokenIdentifier: String
    
    init(estimatedMoetDebt: UFix64, estimatedDebtValue: UFix64, moetPrice: UFix64, loanTokenIdentifier: String) {
        self.estimatedMoetDebt = estimatedMoetDebt
        self.estimatedDebtValue = estimatedDebtValue
        self.moetPrice = moetPrice
        self.loanTokenIdentifier = loanTokenIdentifier
    }
}

access(all) struct HealthMetrics {
    access(all) let realAvailableBalance: UFix64
    access(all) let estimatedCollateralValue: UFix64
    access(all) let liquidationRiskThreshold: UFix64    // DANGER: Below this risks liquidation
    access(all) let autoRebalanceThreshold: UFix64      // AUTO: Triggers rebalancing
    access(all) let optimalHealthRatio: UFix64          // TARGET: Ideal health ratio
    access(all) let maxEfficiencyThreshold: UFix64      // MAX: Upper limit for efficiency
    access(all) let netWorth: UFix64
    access(all) let leverageRatio: UFix64
    access(all) let yieldTokenRatio: UFix64
    access(all) let estimatedHealth: UFix64
    
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

access(all) struct PortfolioSummary {
    access(all) let totalCollateralValue: UFix64
    access(all) let totalYieldTokenValue: UFix64
    access(all) let totalEstimatedDebtValue: UFix64
    access(all) let totalNetWorth: UFix64
    access(all) let averageLeverageRatio: UFix64
    access(all) let portfolioHealthRatio: UFix64
    
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
    let tideManager = getAccount(address).capabilities.borrow<&FlowVaults.TideManager>(FlowVaults.TideManagerPublicPath)
    
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
    
    // Note: FlowALP positions and FlowVaults tides use different ID systems
    // We'll calculate health manually since tide IDs don't correspond to FlowALP position IDs
    
    var totalCollateralValue = 0.0
    var totalYieldTokenValue = 0.0
    var totalEstimatedDebtValue = 0.0
    var totalLeverageRatio = 0.0
    var totalYieldTokenRatio = 0.0
    
    for tideId in tideIds {
        if let tide = tideManager!.borrowTide(id: tideId) {
            let autoBalancer = FlowVaultsAutoBalancers.borrowAutoBalancer(id: tideId)
            let yieldTokenBalance = autoBalancer?.vaultBalance() ?? 0.0
            
            // Use the AutoBalancer's balance as the primary balance source
            // This bypasses the FlowALP overflow issue
            let realAvailableBalance = yieldTokenBalance
            
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
            
            // Get the actual position health from FlowALP.Pool
            // FlowALP positions use sequential IDs (0, 1, 2, ...) while tide IDs are different
            var actualHealth: UFix64 = 999.0
            
            // Try to get the real health from FlowALP.Pool using sequential position IDs
            let protocolAddress = Type<@FlowALP.Pool>().address!
            if let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath) {
                // Since we can't directly map tide IDs to position IDs, we'll try sequential IDs
                // This assumes positions are created in order (0, 1, 2, ...)
                let positionIndex = UInt64(positions.length)  // Use the current position index
                actualHealth = pool.positionHealth(pid: positionIndex)
            }
            
            let estimatedHealth = actualHealth
            
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
                    availableBalance: realAvailableBalance,
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
