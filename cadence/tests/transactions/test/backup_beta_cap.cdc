import "FlowYieldVaultsClosedBeta"

/// Moves the current beta capability from the canonical path to a backup path.
/// Intended for tests that need to retain an "old" beta capability across re-grants.
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        let sourcePath = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        let backupPath = StoragePath(identifier: "FlowYieldVaultsBetaCapBackup")!

        let cap = signer.storage.load<
            Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
        >(from: sourcePath)
            ?? panic("Missing beta capability at \(sourcePath)")

        if let t = signer.storage.type(at: backupPath) {
            if t == Type<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>() {
                let _ = signer.storage.load<
                    Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
                >(from: backupPath)
            } else {
                panic("Unexpected type at backup path: ".concat(t.identifier))
            }
        }

        signer.storage.save(cap, to: backupPath)
    }
}

