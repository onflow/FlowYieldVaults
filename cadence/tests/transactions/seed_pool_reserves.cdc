import "FungibleToken"
import "FlowALPv0"
import "DeFiActions"
import "FungibleTokenConnectors"

/// Seeds the FlowALP pool reserves by creating a position with the provided funds.
/// The position borrows nothing (no drawdown), so the funds sit as collateral in the pool reserves.
transaction(amount: UFix64, vaultStoragePath: StoragePath) {
    let funds: @{FungibleToken.Vault}
    let poolCap: Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>
    let signer: auth(Storage, Capabilities) &Account

    prepare(acct: auth(BorrowValue, Storage, Capabilities) &Account) {
        self.signer = acct
        let vaultRef = acct.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("No vault at \(vaultStoragePath)")
        self.funds <- vaultRef.withdraw(amount: amount)
        self.poolCap = acct.storage.load<Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No pool cap")
    }

    execute {
        let poolRef = self.poolCap.borrow() ?? panic("Invalid pool cap")
        let noopSinkCap = self.signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let noopSink = FungibleTokenConnectors.VaultSink(max: nil, depositVault: noopSinkCap, uniqueID: nil)
        let noopSource = FungibleTokenConnectors.VaultSource(min: nil, withdrawVault: noopSinkCap, uniqueID: nil)
        let position <- poolRef.createPosition(
            funds: <-self.funds,
            issuanceSink: noopSink,
            repaymentSource: noopSource,
            pushToDrawDownSink: false
        )
        self.signer.storage.save(self.poolCap, to: FlowALPv0.PoolCapStoragePath)
        destroy position
    }
}
