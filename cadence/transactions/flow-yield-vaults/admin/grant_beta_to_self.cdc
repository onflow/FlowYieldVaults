import "FlowYieldVaultsClosedBeta"

/// Single-signer variant: admin grants beta access to their own account.
/// Use when the admin is also the test user (avoids multi-sig complexity in shell scripts).
transaction() {
    prepare(admin: auth(BorrowValue, Storage) &Account) {
        let handle = admin.storage.borrow<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
            from: FlowYieldVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle at AdminHandleStoragePath")

        let cap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: admin.address)

        let p = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath

        if let t = admin.storage.type(at: p) {
            if t == Type<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>() {
                let _ = admin.storage.load<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        admin.storage.save(cap, to: p)
    }
}
