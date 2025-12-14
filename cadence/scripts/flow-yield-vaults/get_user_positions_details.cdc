import "FlowYieldVaults"
import "FlowYieldVaultsAutoBalancers"
import "FlowCreditMarket"

/// Returns detailed position information for a user's yield vaults.
/// 
/// @param address: The user's address
/// @param yieldVaultIds: Array of yield vault IDs owned by the user
/// @param positionIds: (Optional) Array of FlowCreditMarket position IDs (aligned with yieldVaultIds)
/// @param debtTokenIdentifier: (Optional) The debt token type identifier (e.g., "A.xxx.MOET.Vault")
///
/// @return UserPositions containing position details
///
/// Note: To get debt info, both positionIds and debtTokenIdentifier must be provided.
///
access(all) struct PositionDetails {
    access(all) let yieldVaultId: UInt64
    access(all) let positionId: UInt64?
    access(all) let collateralTokenIdentifier: String
    access(all) let collateralBalance: UFix64
    access(all) let yieldTokenIdentifier: String?
    access(all) let yieldTokenBalance: UFix64
    access(all) let debtTokenIdentifier: String?
    access(all) let debtBalance: UFix64?
    access(all) let positionHealth: UFix128?

    init(
        yieldVaultId: UInt64,
        positionId: UInt64?,
        collateralTokenIdentifier: String,
        collateralBalance: UFix64,
        yieldTokenIdentifier: String?,
        yieldTokenBalance: UFix64,
        debtTokenIdentifier: String?,
        debtBalance: UFix64?,
        positionHealth: UFix128?
    ) {
        self.yieldVaultId = yieldVaultId
        self.positionId = positionId
        self.collateralTokenIdentifier = collateralTokenIdentifier
        self.collateralBalance = collateralBalance
        self.yieldTokenIdentifier = yieldTokenIdentifier
        self.yieldTokenBalance = yieldTokenBalance
        self.debtTokenIdentifier = debtTokenIdentifier
        self.debtBalance = debtBalance
        self.positionHealth = positionHealth
    }
}

access(all) struct UserPositions {
    access(all) let userAddress: Address
    access(all) let totalPositions: Int
    access(all) let positions: [PositionDetails]

    init(
        userAddress: Address,
        totalPositions: Int,
        positions: [PositionDetails]
    ) {
        self.userAddress = userAddress
        self.totalPositions = totalPositions
        self.positions = positions
    }
}

access(all)
fun main(
    address: Address,
    yieldVaultIds: [UInt64],
    positionIds: [UInt64]?,
    debtTokenIdentifier: String?
): UserPositions {
    // Return empty result if no positions provided
    if yieldVaultIds.length == 0 {
        return UserPositions(
            userAddress: address,
            totalPositions: 0,
            positions: []
        )
    }

    // Validate positionIds length if provided
    if positionIds != nil && positionIds!.length != yieldVaultIds.length {
        panic("Array length mismatch: yieldVaultIds has ".concat(yieldVaultIds.length.toString())
            .concat(" elements but positionIds has ").concat(positionIds!.length.toString()).concat(" elements"))
    }

    // Check if we have position IDs (needed for health) and debt token (needed for debt balance)
    let hasPositionIds = positionIds != nil
    let canFetchDebt = hasPositionIds && debtTokenIdentifier != nil

    // Borrow the user's YieldVaultManager
    let yieldVaultManager = getAccount(address).capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(
        FlowYieldVaults.YieldVaultManagerPublicPath
    )

    if yieldVaultManager == nil {
        panic("No YieldVaultManager found at address ".concat(address.toString()))
    }

    // Borrow FlowCreditMarket Pool if we have position IDs (for health and/or debt info)
    var pool: &FlowCreditMarket.Pool? = nil
    var debtType: Type? = nil
    
    if hasPositionIds {
        let poolAddress = Type<@FlowCreditMarket.Pool>().address!
        pool = getAccount(poolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(
            FlowCreditMarket.PoolPublicPath
        )
        if pool == nil {
            panic("Could not borrow FlowCreditMarket Pool")
        }
        
        // Only parse debt type if debtTokenIdentifier is provided
        if debtTokenIdentifier != nil {
            debtType = CompositeType(debtTokenIdentifier!)
            if debtType == nil {
                panic("Invalid debtTokenIdentifier: ".concat(debtTokenIdentifier!))
            }
        }
    }

    let positions: [PositionDetails] = []

    for i, yieldVaultId in yieldVaultIds {
        // Get YieldVault data for supported types
        let yieldVault = yieldVaultManager!.borrowYieldVault(id: yieldVaultId)
        if yieldVault == nil {
            panic("YieldVault with ID ".concat(yieldVaultId.toString()).concat(" not found for address ").concat(address.toString()))
        }

        // Get collateral type from YieldVault's supported types
        let supportedTypes = yieldVault!.getSupportedVaultTypes()
        let collateralType = supportedTypes.keys[0]
        let collateralTokenIdentifier = collateralType.identifier

        // Yield token info from AutoBalancer
        let autoBalancer = FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: yieldVaultId)
        var yieldTokenIdentifier: String? = nil
        var yieldTokenBalance: UFix64 = 0.0

        if autoBalancer != nil {
            yieldTokenIdentifier = autoBalancer!.vaultType().identifier
            yieldTokenBalance = autoBalancer!.vaultBalance()
        }

        // Position info, health, collateral, and debt (from FlowCreditMarket)
        var positionId: UInt64? = nil
        var collateralBalance: UFix64 = 0.0
        var debtBalance: UFix64? = nil
        var positionHealth: UFix128? = nil

        if hasPositionIds {
            positionId = positionIds![i]
            
            // Get position health
            positionHealth = pool!.positionHealth(pid: positionId!)
            
            // Get position details for collateral and debt balances
            let positionDetails = pool!.getPositionDetails(pid: positionId!)
            for balance in positionDetails.balances {
                // Credit direction = collateral (deposited)
                if balance.vaultType == collateralType && balance.direction == FlowCreditMarket.BalanceDirection.Credit {
                    collateralBalance = balance.balance
                }
                // Debit direction = debt (borrowed)
                if canFetchDebt && balance.vaultType == debtType! && balance.direction == FlowCreditMarket.BalanceDirection.Debit {
                    debtBalance = balance.balance
                }
            }
        }

        positions.append(PositionDetails(
            yieldVaultId: yieldVaultId,
            positionId: positionId,
            collateralTokenIdentifier: collateralTokenIdentifier,
            collateralBalance: collateralBalance,
            yieldTokenIdentifier: yieldTokenIdentifier,
            yieldTokenBalance: yieldTokenBalance,
            debtTokenIdentifier: debtTokenIdentifier,
            debtBalance: debtBalance,
            positionHealth: positionHealth
        ))
    }

    return UserPositions(
        userAddress: address,
        totalPositions: positions.length,
        positions: positions
    )
}
