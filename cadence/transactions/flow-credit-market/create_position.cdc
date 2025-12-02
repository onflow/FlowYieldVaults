
import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowCreditMarket"
import "MOET"
import "FungibleTokenConnectors"

transaction(amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let poolCap = signer.storage
            .borrow<&Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>>(
                from: FlowCreditMarket.PoolCapStoragePath
            ) ?? panic("no Pool capability saved at PoolCapStoragePath")

        let pool = poolCap.borrow()
            ?? panic("cap.borrow() failed (link missing or revoked)")
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow FlowToken vault ref from signer")
	    let flowFunds <- vaultRef.withdraw(amount: amount)

        let depositVaultCap = signer.capabilities.get<&{FungibleToken.Vault}>(MOET.VaultPublicPath)

        assert(depositVaultCap.check(),
            message: "Invalid MOET Vault public Capability issued - ensure the Vault is properly configured")
        let depositSink = FungibleTokenConnectors.VaultSink(
            max: UFix64.max,
            depositVault: depositVaultCap,
            uniqueID: nil
        )
        let pid = pool.createPosition(
            funds: <- flowFunds,
            issuanceSink: depositSink,
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        pool.rebalancePosition(pid: pid, force: true)
    }
    execute {
    }
}
