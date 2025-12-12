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
    access(all) let yieldTokenBalance: UFix64
    access(all) let debtTokenIdentifier: String?
    access(all) let debtBalance: UFix64?

    init(
        yieldVaultId: UInt64,
        positionId: UInt64?,
        collateralTokenIdentifier: String,
        collateralBalance: UFix64,
        yieldTokenBalance: UFix64,
        debtTokenIdentifier: String?,
        debtBalance: UFix64?
    ) {
        self.yieldVaultId = yieldVaultId
        self.positionId = positionId
        self.collateralTokenIdentifier = collateralTokenIdentifier
        self.collateralBalance = collateralBalance
        self.yieldTokenBalance = yieldTokenBalance
        self.debtTokenIdentifier = debtTokenIdentifier
        self.debtBalance = debtBalance
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

    // Check if we can fetch debt info (need both positionIds and debtTokenIdentifier)
    let canFetchDebt = positionIds != nil && debtTokenIdentifier != nil

    // Borrow the user's YieldVaultManager
    let yieldVaultManager = getAccount(address).capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(
        FlowYieldVaults.YieldVaultManagerPublicPath
    )

    if yieldVaultManager == nil {
        panic("No YieldVaultManager found at address ".concat(address.toString()))
    }

    // Borrow FlowCreditMarket Pool if we need debt info
    var pool: &FlowCreditMarket.Pool? = nil
    var debtType: Type? = nil
    
    if canFetchDebt {
        let poolAddress = Type<@FlowCreditMarket.Pool>().address!
        pool = getAccount(poolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(
            FlowCreditMarket.PoolPublicPath
        )
        if pool == nil {
            panic("Could not borrow FlowCreditMarket Pool")
        }
        debtType = CompositeType(debtTokenIdentifier!)
        if debtType == nil {
            panic("Invalid debtTokenIdentifier: ".concat(debtTokenIdentifier!))
        }
    }

    let positions: [PositionDetails] = []

    for i, yieldVaultId in yieldVaultIds {
        // Get YieldVault data
        let yieldVault = yieldVaultManager!.borrowYieldVault(id: yieldVaultId)
        if yieldVault == nil {
            panic("YieldVault with ID ".concat(yieldVaultId.toString()).concat(" not found for address ").concat(address.toString()))
        }

        // Collateral info from YieldVault
        let supportedTypes = yieldVault!.getSupportedVaultTypes()
        let collateralType = supportedTypes.keys[0]
        let collateralTokenIdentifier = collateralType.identifier
        let collateralBalance = yieldVault!.getYieldVaultBalance()

        // Yield token balance from AutoBalancer
        let autoBalancer = FlowYieldVaultsAutoBalancers.borrowAutoBalancer(id: yieldVaultId)
        var yieldTokenBalance: UFix64 = 0.0

        if autoBalancer != nil {
            yieldTokenBalance = autoBalancer!.vaultBalance()
        }

        // Debt info (if available)
        var positionId: UInt64? = nil
        var debtBalance: UFix64? = nil

        if canFetchDebt {
            positionId = positionIds![i]
            debtBalance = pool!.availableBalance(pid: positionId!, type: debtType!, pullFromTopUpSource: false)
        }

        positions.append(PositionDetails(
            yieldVaultId: yieldVaultId,
            positionId: positionId,
            collateralTokenIdentifier: collateralTokenIdentifier,
            collateralBalance: collateralBalance,
            yieldTokenBalance: yieldTokenBalance,
            debtTokenIdentifier: debtTokenIdentifier,
            debtBalance: debtBalance
        ))
    }

    return UserPositions(
        userAddress: address,
        totalPositions: positions.length,
        positions: positions
    )
}
