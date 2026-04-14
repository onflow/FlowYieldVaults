import "FlowYieldVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction() {

    prepare(
        admin: auth(BorrowValue) &Account,
        user:  auth(Storage, Capabilities) &Account
    ) {
        let handle = admin.storage.borrow<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
            from: FlowYieldVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle")

        let cap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: user.address)

        let p = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath

        if let t = user.storage.type(at: p) {
            if t == Type<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>() {
                let _ = user.storage.load<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}
