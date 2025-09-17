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

        user.storage.save(cap, to: TidalYieldClosedBeta.BetaBadgeStoragePath)

        let copyCap = user.capabilities.storage.issue<&{TidalYieldClosedBeta.IBeta}>(TidalYieldClosedBeta.BetaBadgeStoragePath)

        user.capabilities.publish(
           copyCap, 
            at: TidalYieldClosedBeta.BetaBadgePublicPath
        )
    }
}
