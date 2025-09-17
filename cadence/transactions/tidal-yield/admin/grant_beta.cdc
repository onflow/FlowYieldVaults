import "TidalYieldClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and (optionally) publishes it under /public for easy script checks.
transaction(publishPublic: Bool) {

    prepare(
        admin: auth(Capabilities) &Account,
        user:  auth(Storage, Capabilities) &Account
    ) {
        // 1) Admin issues (controller lives in ADMIN)
        let adminCap: Capability<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle> =
        admin.capabilities.storage.issue<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle>(
            TidalYieldClosedBeta.AdminHandleStoragePath
        )
        let handle: auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle =
        adminCap.borrow() ?? panic("Missing AdminHandle")

        let cap: Capability<&{TidalYieldClosedBeta.BetaBadge}> =
        handle.grantBeta(addr: user.address)

        // 2) Save a COPY of the capability value in the user's /storage
        let userCapPath = StoragePath(identifier: "TY_UserBetaCap")!
        user.storage.save(cap, to: userCapPath)

        // 3) Optionally publish in /public for scriptable checks
        if publishPublic {
            let userPubPath = PublicPath(identifier: "TY_Beta")!
            user.capabilities.publish<&{TidalYieldClosedBeta.BetaBadge}>(userCapPath, at: userPubPath)
        }
    }
}
