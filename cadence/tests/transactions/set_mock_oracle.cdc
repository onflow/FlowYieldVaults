import "FlowCreditMarket"
import "MockOracle"
import "DeFiActions"

/// Updates the pool's price oracle to use MockOracle
/// This is useful for testing purposes where we want to control token prices
///
transaction() {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath) - ensure a Pool has been configured")
        
        // Create a MockOracle.PriceOracle - the unitOfAccount will be set based on the pool's default token
        self.oracle = MockOracle.PriceOracle()
    }

    execute {
        self.pool.setPriceOracle(self.oracle)
    }
}

