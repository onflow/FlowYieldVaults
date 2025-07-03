import "Tidal"
import "TidalYieldAutoBalancers"
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
    access(all) let supportedTypes: [String]
    
    init(collateralType: String, availableBalance: UFix64, collateralValue: UFix64, supportedTypes: [String]) {
        self.collateralType = collateralType
        self.availableBalance = availableBalance
        self.collateralValue = collateralValue
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
    access(all) let minHealth: UFix64
    access(all) let targetHealth: UFix64
    access(all) let maxHealth: UFix64
    access(all) let lowerThreshold: UFix64
    access(all) let upperThreshold: UFix64
    access(all) let estimatedLeverageRatio: UFix64
    access(all) let autoBalancerValueRatio: UFix64
    
    init(
        realAvailableBalance: UFix64,
        estimatedCollateralValue: UFix64,
        estimatedLeverageRatio: UFix64,
        autoBalancerValueRatio: UFix64
    ) {
        self.realAvailableBalance = realAvailableBalance
        self.estimatedCollateralValue = estimatedCollateralValue
        self.minHealth = 1.1
        self.targetHealth = 1.3
        self.maxHealth = 1.5
        self.lowerThreshold = 1.1 
        self.upperThreshold = 1.5
        self.estimatedLeverageRatio = estimatedLeverageRatio
        self.autoBalancerValueRatio = autoBalancerValueRatio
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
    access(all) let totalAvailableBalance: UFix64
    access(all) let totalYieldTokenValue: UFix64
    access(all) let totalEstimatedDebtValue: UFix64
    access(all) let totalEstimatedNetWorth: UFix64
    access(all) let averageLeverageRatio: UFix64
    access(all) let averageAutoBalancerRatio: UFix64
    
    init(
        totalAvailableBalance: UFix64,
        totalYieldTokenValue: UFix64,
        totalEstimatedDebtValue: UFix64,
        totalEstimatedNetWorth: UFix64,
        averageLeverageRatio: UFix64,
        averageAutoBalancerRatio: UFix64
    ) {
        self.totalAvailableBalance = totalAvailableBalance
        self.totalYieldTokenValue = totalYieldTokenValue
        self.totalEstimatedDebtValue = totalEstimatedDebtValue
        self.totalEstimatedNetWorth = totalEstimatedNetWorth
        self.averageLeverageRatio = averageLeverageRatio
        self.averageAutoBalancerRatio = averageAutoBalancerRatio
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
                totalAvailableBalance: 0.0,
                totalYieldTokenValue: 0.0,
                totalEstimatedDebtValue: 0.0,
                totalEstimatedNetWorth: 0.0,
                averageLeverageRatio: 0.0,
                averageAutoBalancerRatio: 0.0
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
    
    var totalAvailableBalance = 0.0
    var totalYieldTokenValue = 0.0
    var totalEstimatedDebtValue = 0.0
    var totalLeverageRatio = 0.0
    var totalAutoBalancerRatio = 0.0
    
    for tideId in tideIds {
        if let tide = tideManager!.borrowTide(id: tideId) {
            let realAvailableBalance = tide.getTideBalance()
            
            let autoBalancer = TidalYieldAutoBalancers.borrowAutoBalancer(id: tideId)
            let yieldTokenBalance = autoBalancer?.vaultBalance() ?? 0.0
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
            let autoBalancerValueRatio = expectedYieldTokenValue > 0.0 ? 
                yieldTokenValue / expectedYieldTokenValue : 1.0
            
            let totalPositionValue = estimatedCollateralValue + yieldTokenValue
            let estimatedLeverageRatio = estimatedCollateralValue > 0.0 ? 
                totalPositionValue / estimatedCollateralValue : 1.0
            
            let healthMetrics = HealthMetrics(
                realAvailableBalance: realAvailableBalance,
                estimatedCollateralValue: estimatedCollateralValue,
                estimatedLeverageRatio: estimatedLeverageRatio,
                autoBalancerValueRatio: autoBalancerValueRatio
            )
            
            positions.append(CompletePositionInfo(
                tideId: tideId,
                collateralInfo: CollateralInfo(
                    collateralType: collateralType,
                    availableBalance: realAvailableBalance,
                    collateralValue: estimatedCollateralValue,
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
            
            totalAvailableBalance = totalAvailableBalance + realAvailableBalance
            totalYieldTokenValue = totalYieldTokenValue + yieldTokenValue
            totalEstimatedDebtValue = totalEstimatedDebtValue + estimatedDebtValue
            totalLeverageRatio = totalLeverageRatio + estimatedLeverageRatio
            totalAutoBalancerRatio = totalAutoBalancerRatio + autoBalancerValueRatio
        }
    }
    
    let totalEstimatedNetWorth = totalAvailableBalance + totalYieldTokenValue - totalEstimatedDebtValue
    let averageLeverageRatio = tideIds.length > 0 ? totalLeverageRatio / UFix64(tideIds.length) : 0.0
    let averageAutoBalancerRatio = tideIds.length > 0 ? totalAutoBalancerRatio / UFix64(tideIds.length) : 0.0
    
    return CompleteUserSummary(
        userAddress: address,
        totalPositions: tideIds.length,
        portfolioSummary: PortfolioSummary(
            totalAvailableBalance: totalAvailableBalance,
            totalYieldTokenValue: totalYieldTokenValue,
            totalEstimatedDebtValue: totalEstimatedDebtValue,
            totalEstimatedNetWorth: totalEstimatedNetWorth,
            averageLeverageRatio: averageLeverageRatio,
            averageAutoBalancerRatio: averageAutoBalancerRatio
        ),
        positions: positions
    )
} 