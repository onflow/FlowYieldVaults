import "FlowALP"

transaction(pid: UInt64, force: Bool) {
    let pool: auth(FlowALP.EPosition) &FlowALP.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EPosition) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALP.PoolStoragePath) - ensure a Pool has been configured")
    }
    
    execute {
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}
