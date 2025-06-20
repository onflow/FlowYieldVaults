import "TidalProtocol"

transaction(pid: UInt64, force: Bool) {
    let pool: auth(TidalProtocol.EPosition) &TidalProtocol.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(TidalProtocol.PoolStoragePath) - ensure a Pool has been configured")
    }
    
    execute {
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}