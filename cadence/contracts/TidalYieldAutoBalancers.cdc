import "Burner"
import "FungibleToken"

import "DFB"

access(all) contract TidalYieldAutoBalancers {

    /// The path prefix used for StoragePath & PublicPath derivations
    access(all) let pathPrefix: String
    
    /* --- PUBLIC METHODS --- */

    /// Returns the path (StoragePath or PublicPath) at which an AutoBalancer is stored with the associated 
    /// UniqueIdentifier.id. 
    access(all) view fun deriveAutoBalancerPath(id: UInt64, storage: Bool): Path {
        return storage ? StoragePath(identifier: "\(self.pathPrefix)\(id)")! : PublicPath(identifier: "\(self.pathPrefix)\(id)")!
    }

    /// Returns an unauthorized reference to an AutoBalancer with the given UniqueIdentifier.id value. If none is
    /// configured, `nil` will be returned.
    access(all) fun borrowAutoBalancer(id: UInt64): &DFB.AutoBalancer? {
        let publicPath = self.deriveAutoBalancerPath(id: id, storage: false) as! PublicPath
        return self.account.capabilities.borrow<&DFB.AutoBalancer>(publicPath)
    }

    /* --- INTERNAL METHODS --- */

    /// Configures a new AutoBalancer in storage, configures its public Capability, and sets its inner authorized
    /// Capability. If an AutoBalancer is stored with an associated UniqueID value, the operation reverts.
    access(account) fun _initNewAutoBalancer(
        oracle: {DFB.PriceOracle},
        vaultType: Type,
        lowerThreshold: UFix64,
        upperThreshold: UFix64,
        rebalanceSink: {DFB.Sink}?,
        rebalanceSource: {DFB.Source}?,
        uniqueID: DFB.UniqueIdentifier
    ): auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFB.AutoBalancer {
        
        // derive paths & prevent collision
        let storagePath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: true) as! StoragePath
        let publicPath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: false) as! PublicPath
        var storedType = self.account.storage.type(at: storagePath)
        var publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == nil,
            message: "Storage collision when creating AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(!publishedCap,
            message: "Published Capability collision found when publishing AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")

        // create & save AutoBalancer
        let autoBalancer <- DFB.createAutoBalancer(
                oracle: oracle,
                vaultType: vaultType,
                lowerThreshold: lowerThreshold,
                upperThreshold: upperThreshold,
                rebalanceSink: rebalanceSink,
                rebalanceSource: rebalanceSource,
                uniqueID: uniqueID
            )
        self.account.storage.save(<-autoBalancer, to: storagePath)
        let autoBalancerRef = self._borrowAutoBalancer(uniqueID.id)

        // issue & publish public capability
        let publicCap = self.account.capabilities.storage.issue<&DFB.AutoBalancer>(storagePath)
        self.account.capabilities.publish(publicCap, at: publicPath)

        // issue private capability & set within AutoBalancer
        let authorizedCap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw) &DFB.AutoBalancer>(storagePath)
        autoBalancerRef.setSelfCapability(authorizedCap)

        // ensure proper configuration before closing
        storedType = self.account.storage.type(at: storagePath)
        publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == Type<@DFB.AutoBalancer>(),
            message: "Error when configuring AutoBalancer for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(!publishedCap,
            message: "Error when publishing AutoBalancer Capability for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")
        return autoBalancerRef
    }

    /// Returns an authorized reference on the AutoBalancer with the associated UniqueIdentifier.id. If none is found,
    /// the operation reverts.
    access(account)
    fun _borrowAutoBalancer(_ id: UInt64): auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFB.AutoBalancer {
        let storagePath = self.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        return self.account.storage.borrow<auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFB.AutoBalancer>(
                from: storagePath
            ) ?? panic("Could not borrow reference to AutoBalancer with UniqueIdentifier.id \(id) from StoragePath \(storagePath)")
    }

    /// Called by strategies defined in the TidalYield account which leverage account-hosted AutoBalancers when a
    /// Strategy is burned
    access(account) fun _cleanupAutoBalancer(id: UInt64) {
        let storagePath = self.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        let publicPath = self.deriveAutoBalancerPath(id: id, storage: false) as! PublicPath
        // unpublish the public AutoBalancer Capability
        self.account.capabilities.unpublish(publicPath)
        // delete any CapabilityControllers targetting the AutoBalancer
        self.account.capabilities.storage.forEachController(forPath: storagePath, fun(_ controller: &StorageCapabilityController): Bool {
            controller.delete()
            return true
        })
        // load & burn the AutoBalancer
        let autoBalancer <-self.account.storage.load<@DFB.AutoBalancer>(from: storagePath)
        Burner.burn(<-autoBalancer)
    }

    init() {
        self.pathPrefix = "TidalYieldAutoBalancer_"
    }
}
