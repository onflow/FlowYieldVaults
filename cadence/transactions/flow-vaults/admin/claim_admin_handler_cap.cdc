import "FlowVaultsClosedBeta"

/// Run this with the *recipient* account as the signer
/// and pass the provider's address (who published to inbox) as an argument.
transaction(provider: Address) {

    // Needs Inbox to claim, Capabilities if you want to re-publish the cap
    prepare(
        acct: auth(Inbox, Storage) &Account
    ) {
        // Claim the capability from the provider's inbox
        let claimedCap = acct.inbox.claim<
            auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle
        >(
            "flow-vaults-admin-handle",
            provider: provider
        ) ?? panic("No AdminHandle capability available in inbox")

        acct.storage.save(
            claimedCap,
            to: /storage/flowVaultsAdminHandleCap
        )
    }

    execute {}
}
