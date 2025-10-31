
import "FlowVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(addr: Address) {
    prepare(
        admin: auth(Capabilities) &Account,
    ) {
        let adminCap: Capability<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle> =
            admin.capabilities.storage.issue<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
                FlowVaultsClosedBeta.AdminHandleStoragePath
            )
        let handle: auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle =
            adminCap.borrow() ?? panic("Missing AdminHandle")

        handle.revokeByAddress(addr: addr)
    }
}
