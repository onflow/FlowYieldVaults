import "FlowYieldVaultsClosedBeta"

/// Returns the number of addresses that have been granted beta access and have not been revoked.
access(all) fun main(): Int {
    var active = 0
    for addr in FlowYieldVaultsClosedBeta.issuedCapIDs.keys {
        if !FlowYieldVaultsClosedBeta.issuedCapIDs[addr]!.isRevoked {
            active = active + 1
        }
    }
    return active
}
