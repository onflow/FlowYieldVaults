import "FlowVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction() {

    prepare(
        admin: auth(BorrowValue) &Account,
        user:  auth(Storage, Capabilities) &Account
    ) {
        let handle = admin.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
            from: FlowVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle")

        let cap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: user.address)

        let p = FlowVaultsClosedBeta.UserBetaCapStoragePath

        if let t = user.storage.type(at: p) {
            if t == Type<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>() {
                let _ = user.storage.load<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}
