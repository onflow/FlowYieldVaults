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

        let cap: Capability<&{TidalYieldClosedBeta.IBeta}> =
        handle.grantBeta(addr: user.address)

        let p = TidalYieldClosedBeta.UserBetaCapStoragePath

        // 1) Clear whatever is currently at `p`
        log(user.storage.type(at:p))

        if let t = user.storage.type(at: p) {
            log(t)
            if t == Type<@TidalYieldClosedBeta.BetaBadge>() {
                log("old")
                // Remove old resource
                let old <- user.storage.load<@TidalYieldClosedBeta.BetaBadge>(from: p)
                ?? panic("Expected BetaBadge but it disappeared")
                destroy old
            } else if t == Type<Capability<&{TidalYieldClosedBeta.IBeta}>>() {
                // Remove old capability value
                let _ = user.storage.load<Capability<&{TidalYieldClosedBeta.IBeta}>>(from: p)
                // no destroy needed; it's a value, just drop it
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

        let copyCap = user.capabilities.storage.issue<&{TidalYieldClosedBeta.IBeta}>(p)

        let pubPath = TidalYieldClosedBeta.BetaBadgePublicPath

        // If anything is already published there, remove it first
        let existingAny = user.capabilities.exists(pubPath)
        if existingAny {
            user.capabilities.unpublish(pubPath)
        }

        user.capabilities.publish(
            copyCap, 
            at: TidalYieldClosedBeta.BetaBadgePublicPath
        )
    }
}
