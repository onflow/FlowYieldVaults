import "AutoBalancers"
import "FlowYieldVaultsAutoBalancersV1"

transaction(id: UInt64, force: Bool) {
    let autoBalancer: auth(AutoBalancers.Auto) &AutoBalancers.AutoBalancer

    prepare(signer: auth(BorrowValue) &Account) {
        let storagePath = FlowYieldVaultsAutoBalancersV1.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        self.autoBalancer = signer.storage.borrow<auth(AutoBalancers.Auto) &AutoBalancers.AutoBalancer>(from: storagePath)
            ?? panic("Could not borrow reference to AutoBalancer id \(id) at path \(storagePath)")
    }

    execute {
        self.autoBalancer.rebalance(force: force)
    }
}
