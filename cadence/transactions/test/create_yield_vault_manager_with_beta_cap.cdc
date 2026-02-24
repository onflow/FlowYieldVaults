import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"

/// Creates (and destroys) a YieldVaultManager using the caller's stored beta capability.
transaction {
    let betaRef: auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let betaCap = signer.storage.copy<
            Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
        >(from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Missing Beta capability at \(FlowYieldVaultsClosedBeta.UserBetaCapStoragePath)")

        self.betaRef = betaCap.borrow()
            ?? panic("Beta capability does not contain correct reference")
    }

    execute {
        let manager <- FlowYieldVaults.createYieldVaultManager(betaRef: self.betaRef)
        destroy manager
    }
}

