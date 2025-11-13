import "FlowVaultsClosedBeta"

/// Saves a copy of the admin-issued cap into the user's account
/// and publishes it under /public for easy script checks.
transaction(adminAddr: Address) {

    prepare(
        user:  auth(Storage, Capabilities, ClaimInboxCapability) &Account
    ) {
        let p = FlowVaultsClosedBeta.UserBetaCapStoragePath
        let cap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge> =
            user.inbox.claim<
                auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge
                >("FlowVaultsBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")
        if let t = user.storage.type(at: p) {
            if t == Type<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>() {
                let _ = user.storage.load<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: p)
            } else {
                panic("Unexpected type at UserBetaCapStoragePath: ".concat(t.identifier))
            }
        }
        user.storage.save(cap, to: p)

    }
}

