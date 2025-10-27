import "MockV3"

transaction(percent: UFix64) {
    prepare(signer: &Account) {
        let cap = getAccount(signer.address).capabilities.get<&MockV3.Pool>(MockV3.PoolPublicPath)
        let pool = cap.borrow()
            ?? panic("MockV3 pool not found")
        pool.drainLiquidity(percent: percent)
    }
}


