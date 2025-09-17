import "TidalYieldClosedBeta"

access(all) fun main(addr: Address): Bool {
    return getAccount(addr).capabilities.exists(TidalYieldClosedBeta.BetaBadgePublicPath)
}
