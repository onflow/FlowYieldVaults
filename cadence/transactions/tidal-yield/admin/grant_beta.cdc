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

        let cap: Capability<&TidalYieldClosedBeta.BetaBadge> =
        handle.grantBeta(addr: user.address)

        let p = TidalYieldClosedBeta.UserBetaCapStoragePath

        // 1) Clear whatever is currently at `p`
        if let t = user.storage.type(at: p) {
            if t == Type<@TidalYieldClosedBeta.BetaBadge>() {
                // Remove old resource
                let old <- user.storage.load<@TidalYieldClosedBeta.BetaBadge>(from: p)
                ?? panic("Expected BetaBadge but it disappeared")
                destroy old
            } else if t == Type<Capability<&TidalYieldClosedBeta.BetaBadge>>() {
                // Remove old capability value
                let _ = user.storage.load<Capability<&TidalYieldClosedBeta.BetaBadge>>(from: p)
                // no destroy needed; it's a value, just drop it
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}
