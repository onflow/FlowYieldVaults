import FlowALPv0 from "FlowALPv0"

transaction(pid: UInt64, minHealth: UFix64, targetHealth: UFix64, maxHealth: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let pool = signer.storage.borrow<auth(FlowALPv0.EPosition) &FlowALPv0.Pool>(
            from: FlowALPv0.PoolStoragePath
        ) ?? panic("Could not borrow Pool")

        let position = pool.borrowPosition(pid: pid)

        // Each setter enforces minHealth < targetHealth < maxHealth independently,
        // so we must widen the range before narrowing to avoid intermediate violations.
        position.setMinHealth(1.00000001)
        position.setMaxHealth(UFix128.max)
        position.setTargetHealth(UFix128(targetHealth))
        position.setMinHealth(UFix128(minHealth))
        position.setMaxHealth(UFix128(maxHealth))
    }
}
