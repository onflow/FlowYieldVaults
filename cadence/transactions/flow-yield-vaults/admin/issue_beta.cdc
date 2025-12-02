import "FlowYieldVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(grantee: Address) {

    prepare(
        admin: auth(BorrowValue, PublishInboxCapability) &Account,
    ) {
        let handle = admin.storage.borrow<auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle>(
            from: FlowYieldVaultsClosedBeta.AdminHandleStoragePath
        ) ?? panic("Missing AdminHandle")

        let cap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> =
            handle.grantBeta(addr: grantee)

        assert(cap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(cap, name: "FlowYieldVaultsBetaCap", recipient: grantee)
    }
}
