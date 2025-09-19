
import "TidalYieldClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(addr: Address) {
    prepare(
        admin: auth(Capabilities) &Account,
    ) {
        let adminCap: Capability<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle> =
            admin.capabilities.storage.issue<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle>(
                TidalYieldClosedBeta.AdminHandleStoragePath
            )
        let handle: auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle =
            adminCap.borrow() ?? panic("Missing AdminHandle")

        handle.revokeByAddress(addr: addr)
    }
}
