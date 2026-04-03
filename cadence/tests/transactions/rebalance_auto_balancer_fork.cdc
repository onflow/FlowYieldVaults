import "DeFiActions"
import "FlowYieldVaultsAutoBalancers"

transaction(id: UInt64, force: Bool) {
    let autoBalancer: auth(DeFiActions.Auto) &DeFiActions.AutoBalancer

    prepare(signer: auth(BorrowValue) &Account) {
        let storagePath = FlowYieldVaultsAutoBalancers.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        self.autoBalancer = signer.storage.borrow<auth(DeFiActions.Auto) &DeFiActions.AutoBalancer>(from: storagePath)
            ?? panic("Could not borrow reference to AutoBalancer id \(id) at path \(storagePath)")
    }

    execute {
        self.autoBalancer.rebalance(force: force)
    }
}
