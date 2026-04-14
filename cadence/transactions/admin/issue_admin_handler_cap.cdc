import "FlowYieldVaultsClosedBeta"

transaction(recipient: Address) {
    prepare(
        acct: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account
    ) {
        // Issue a storage capability to the AdminHandle resource
        let adminCap = acct.capabilities.storage.issue<
            auth(FlowYieldVaultsClosedBeta.Admin) &FlowYieldVaultsClosedBeta.AdminHandle
        >(FlowYieldVaultsClosedBeta.AdminHandleStoragePath)
        assert(adminCap.check(), message: "Invalid AdminHandle Capability issued")

        // Publish that capability into this account's inbox
        // under some agreed name, for this specific recipient
        acct.inbox.publish(
            adminCap,
            name: "flow-yield-vaults-admin-handle",
            recipient: recipient
        )
    }

    execute {}
}
