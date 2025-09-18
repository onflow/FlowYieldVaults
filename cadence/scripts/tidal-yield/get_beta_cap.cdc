import "TidalYieldClosedBeta"

access(all) fun main(addr: Address): Bool {
    let capExists = getAccount(addr).capabilities.exists(TidalYieldClosedBeta.BetaBadgePublicPath)
    if !capExists {
        return false
    }
    let betaCapID = TidalYieldClosedBeta.getBetaCapID(addr)
    let existingCap = getAccount(addr).capabilities.get<&{TidalYieldClosedBeta.IBeta}>(TidalYieldClosedBeta.BetaBadgePublicPath)

    return existingCap.id != nil && betaCapID != nil
}
