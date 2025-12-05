
import "FlowYieldVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(addr: Address) {
    prepare(
        admin: auth(Capabilities) &Account,
    ) {
        let adminCap: Capability<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle> =
            admin.capabilities.storage.issue<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
                FlowYieldVaultsClosedBeta.AdminHandleStoragePath
            )
        let handle: auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle =
            adminCap.borrow() ?? panic("Missing AdminHandle")

        handle.revokeByAddress(addr: addr)
    }
}
