import "FlowALPv0"

/// Sets target, min, and max health params on a Pool's InternalPosition directly.
/// Must be signed by the Pool owner (flowALPAccount).
transaction(pid: UInt64, targetHealth: UFix64, minHealth: UFix64, maxHealth: UFix64) {
    let pool: auth(FlowALPv0.EPosition) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EPosition) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from storage")
    }

    execute {
        let pos = self.pool.borrowPosition(pid: pid)
        let newTarget = UFix128(targetHealth)
        let newMin = UFix128(minHealth)
        let newMax = UFix128(maxHealth)

        // these calls enforce the constraints minHealth < targetHealth < maxHealth
        // so we keep the widest constraints first, then tighten later
        if newMax > pos.maxHealth {
            pos.setMaxHealth(newMax)
        }
        if newMin < pos.minHealth {
            pos.setMinHealth(newMin)
        }
        pos.setTargetHealth(newTarget)
        pos.setMaxHealth(newMax)
        pos.setMinHealth(newMin)
    }
}
