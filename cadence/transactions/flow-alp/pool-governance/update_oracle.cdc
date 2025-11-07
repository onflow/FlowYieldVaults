import "FlowALP"
import "BandOracle"
import "BandOracleConnectors"
import "DeFiActions"
import "FungibleTokenConnectors"
import "FungibleToken"

/// Adds a token type as supported to the stored pool, reverting if a Pool is not found
///
transaction() {
    let pool: auth(FlowALP.EGovernance) &FlowALP.Pool
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EGovernance) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALP.PoolStoragePath) - ensure a Pool has been configured")
        let defaultToken = self.pool.getDefaultToken()
        log(defaultToken)

        let vaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSource(min: nil, withdrawVault: vaultCap, uniqueID: nil)
        self.oracle = BandOracleConnectors.PriceOracle(
            unitOfAccount: defaultToken,
            staleThreshold: 3600,
            feeSource: feeSource,
            uniqueID: nil,
        )
    }

    execute {
        self.pool.setPriceOracle(
            self.oracle
        )
    }
}
