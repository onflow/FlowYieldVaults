import "FlowVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(grantee: Address) {

    prepare(
        admin: auth(CopyValue, PublishInboxCapability) &Account
    ) {
        let adminHandleCap = admin.storage.copy<Capability<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>>(
            from: /storage/flowVaultsAdminHandleCap
        ) ?? panic("Missing AdminHandleCap")

        let handle = adminHandleCap.borrow()
            ?? panic("Cannot borrow auth AdminHandle")
        
        let cap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: grantee)

        assert(cap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(cap, name: "FlowVaultsBetaCap", recipient: grantee)
    }
}
