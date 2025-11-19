import "FlowVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(grantee: Address) {

    prepare(
        admin: auth(BorrowValue, PublishInboxCapability) &Account,
    ) {
        let handle = admin.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
            from: FlowVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle")

        let cap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: grantee)

        assert(cap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(cap, name: "FlowVaultsBetaCap", recipient: grantee)
    }
}
