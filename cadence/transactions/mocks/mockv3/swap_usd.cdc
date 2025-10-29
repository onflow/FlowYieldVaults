import "MockV3"

transaction(amountUSD: UFix64) {
    prepare(signer: &Account) {
        let cap = getAccount(signer.address).capabilities.get<&MockV3.Pool>(MockV3.PoolPublicPath)
        let pool = cap.borrow()
            ?? panic("MockV3 pool not found")
        let ok = pool.swap(amountUSD: amountUSD)
        assert(ok, message: "swap failed (range broken)")
    }
}


