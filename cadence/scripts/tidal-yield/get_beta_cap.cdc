import "TidalYieldClosedBeta"

access(all) fun main(addr: Address): Bool {
    log(addr)
    let cap: Capability<&{TidalYieldClosedBeta.IBeta}> =
    getAccount(addr).capabilities.get<&{TidalYieldClosedBeta.IBeta}>(
        /public/TidalYieldBetaBadge
    )
    log(cap)
    return cap.check()
}
