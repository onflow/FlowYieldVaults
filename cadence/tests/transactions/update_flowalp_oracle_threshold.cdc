import "FlowALPv0"
import "BandOracleConnectors"
import "DeFiActions"
import "FungibleTokenConnectors"
import "FungibleToken"

/// Updates the FlowALP pool's price oracle with a larger staleThreshold.
///
/// Use in fork testing environments where Band oracle data may be up to
/// several hours old. The emulator fork uses mainnet state at a fixed
/// height; as real time advances the oracle data becomes stale.
///
/// @param staleThreshold: seconds beyond which oracle data is considered stale
///                        Use 86400 (24h) for long-running fork test sessions.
///
/// Must be signed by the FlowALP pool owner (6b00ff876c299c61).
/// In fork mode, signature validation is disabled, so any key can be used.
transaction(staleThreshold: UInt64) {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath)")
        let defaultToken = self.pool.getDefaultToken()

        let vaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSource(min: nil, withdrawVault: vaultCap, uniqueID: nil)
        self.oracle = BandOracleConnectors.PriceOracle(
            unitOfAccount: defaultToken,
            staleThreshold: staleThreshold,
            feeSource: feeSource,
            uniqueID: nil,
        )
    }

    execute {
        self.pool.setPriceOracle(self.oracle)
        log("FlowALP oracle staleThreshold updated to \(staleThreshold)s")
    }
}
