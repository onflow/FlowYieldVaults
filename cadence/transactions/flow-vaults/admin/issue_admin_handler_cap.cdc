import "FlowVaultsClosedBeta"

transaction(recipient: Address) {
    prepare(
        acct: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account
    ) {
        // Issue a storage capability to the AdminHandle resource
        let adminCap = acct.capabilities.storage.issue<
            auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle
        >(FlowVaultsClosedBeta.AdminHandleStoragePath)
        assert(adminCap.check(), message: "Invalid AdminHandle Capability issued")

        // Publish that capability into this account's inbox
        // under some agreed name, for this specific recipient
        acct.inbox.publish(
            adminCap,
            name: "flow-vaults-admin-handle",
            recipient: recipient
        )
    }

    execute {}
}
