import "TidalYieldClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction() {

    prepare(
        admin: auth(Capabilities) &Account,
        user:  auth(Storage, Capabilities) &Account
    ) {
        let adminCap: Capability<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle> =
            admin.capabilities.storage.issue<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle>(
                TidalYieldClosedBeta.AdminHandleStoragePath
            )
        let handle: auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle =
            adminCap.borrow() ?? panic("Missing AdminHandle")

        let cap: Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge> =
            handle.grantBeta(addr: user.address)

        let p = TidalYieldClosedBeta.UserBetaCapStoragePath

        if let t = user.storage.type(at: p) {
            if t == Type<Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>>() {
                let _ = user.storage.load<Capability<&TidalYieldClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}
