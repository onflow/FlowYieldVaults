import "TidalYieldClosedBeta"

access(all) fun main(addr: Address): Bool {
    let acct = getAuthAccount<auth(Storage) &Account>(addr)
    let betaCapID = TidalYieldClosedBeta.getBetaCapID(addr)
    let existingCap = acct.storage.borrow<Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>>(
        from: TidalYieldClosedBeta.UserBetaCapStoragePath
    ) ?? panic("Missing beta capability")
    return betaCapID != nil && existingCap.id == betaCapID
}
