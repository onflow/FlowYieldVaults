import "FlowYieldVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(grantee: Address) {

    prepare(
        admin: auth(CopyValue, PublishInboxCapability) &Account
    ) {
        let adminHandleCap = admin.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>>(
            from: /storage/flowYieldVaultsAdminHandleCap
        ) ?? panic("Missing AdminHandleCap")

        let handle = adminHandleCap.borrow()
            ?? panic("Cannot borrow auth AdminHandle")
        
        let cap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: grantee)

        assert(cap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(cap, name: "FlowYieldVaultsBetaCap", recipient: grantee)
    }
}
