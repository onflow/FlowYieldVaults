import "TidalProtocol"

/// Rebalances a position to its target health
transaction(pid: UInt64, force: Bool) {
    prepare(signer: auth(Storage) &Account) {
        let poolCap = signer.storage.load<Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>>(
            from: TidalProtocol.PoolCapStoragePath
        ) ?? panic("Missing pool capability")
        
        let pool = poolCap.borrow() ?? panic("Invalid Pool Cap")
        pool.rebalancePosition(pid: pid, force: force)
        
        // Save the capability back
        signer.storage.save(poolCap, to: TidalProtocol.PoolCapStoragePath)
    }
}

