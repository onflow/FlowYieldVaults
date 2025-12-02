import "FlowYieldVaultsClosedBeta"

access(all) fun main(addr: Address): Bool {
    let acct = getAuthAccount<auth(Storage) &Account>(addr)
    let betaCapID = FlowYieldVaultsClosedBeta.getBetaCapID(addr)
    let existingCap = acct.storage.borrow<&Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
        from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
    )
    return betaCapID != nil && existingCap?.id == betaCapID
}
