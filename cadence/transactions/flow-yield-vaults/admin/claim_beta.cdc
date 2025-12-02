import "FlowYieldVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(adminAddr: Address) {

    prepare(
        user:  auth(Storage, Capabilities, ClaimInboxCapability) &Account
    ) {
        let p = FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        let cap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> =
            user.inbox.claim<
                auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge
                >("FlowYieldVaultsBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")
        if let t = user.storage.type(at: p) {
            if t == Type<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>() {
                let _ = user.storage.load<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}

