import "FlowYieldVaultsClosedBeta"

/// Asserts that the beta capability stored at the backup path has been revoked.
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let backupPath = StoragePath(identifier: "FlowYieldVaultsBetaCapBackup")!

        let cap = signer.storage.load<
            Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
        >(from: backupPath)
            ?? panic("Missing beta capability at backup path \(backupPath)")

        assert(!cap.check(), message: "Expected backup beta capability to be revoked")
    }
}

