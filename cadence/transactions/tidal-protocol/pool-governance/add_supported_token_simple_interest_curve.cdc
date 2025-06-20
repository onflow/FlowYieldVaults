import "TidalProtocol"

/// Adds a token type as supported to the stored pool, reverting if a Pool is not found
///
transaction(
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
) {
    let tokenType: Type
    let pool: auth(TidalProtocol.EGovernance) &TidalProtocol.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(TidalProtocol.EGovernance) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(TidalProtocol.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.addSupportedToken(
            tokenType: self.tokenType,
            collateralFactor: collateralFactor,
            borrowFactor: borrowFactor,
            interestCurve: TidalProtocol.SimpleInterestCurve(),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
