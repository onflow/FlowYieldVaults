import "FlowVaultsClosedBeta"

access(all) fun main(addr: Address): Bool {
    let acct = getAuthAccount<auth(Storage) &Account>(addr)
    let betaCapID = FlowVaultsClosedBeta.getBetaCapID(addr)
    let existingCap = acct.storage.borrow<&Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
        from: FlowVaultsClosedBeta.UserBetaCapStoragePath
    )
    return betaCapID != nil && existingCap?.id == betaCapID
}
