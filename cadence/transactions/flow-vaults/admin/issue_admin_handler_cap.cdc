import "FlowVaultsClosedBeta"

transaction(recipient: Address) {
    prepare(
        acct: auth(Storage, Capabilities, Inbox) &Account
    ) {
        // Issue a storage capability to the AdminHandle resource
        let adminCap = acct.capabilities.storage.issue<
            auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle
        >(FlowVaultsClosedBeta.AdminHandleStoragePath)

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
