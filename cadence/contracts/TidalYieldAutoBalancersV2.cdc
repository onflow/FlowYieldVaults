// standards
import "Burner"
import "FungibleToken"
// DeFiBlocks
import "DFB"
import "DFBv2"
import "DFBUtils"

/// TidalYieldAutoBalancersV2
///
/// This contract manages high-precision AutoBalancerV2 resources for TidalYield strategies.
/// It provides the same functionality as TidalYieldAutoBalancers but uses UInt256 calculations
/// for improved precision.
///
access(all) contract TidalYieldAutoBalancersV2 {

    /// The path prefix used for StoragePath & PublicPath derivations
    access(all) let pathPrefix: String

    /* --- PUBLIC METHODS --- */

    /// Returns the path at which an AutoBalancerV2 is stored
    access(all) view fun deriveAutoBalancerPath(id: UInt64, storage: Bool): Path {
        return storage ? StoragePath(identifier: "\(self.pathPrefix)\(id)")! : PublicPath(identifier: "\(self.pathPrefix)\(id)")!
    }

    /// Returns a reference to an AutoBalancerV2 with the given ID
    access(all) fun borrowAutoBalancer(id: UInt64): &DFBv2.AutoBalancerV2? {
        let publicPath = self.deriveAutoBalancerPath(id: id, storage: false) as! PublicPath
        return self.account.capabilities.borrow<&DFBv2.AutoBalancerV2>(publicPath)
    }

    /* --- INTERNAL METHODS --- */

    /// Creates and configures a new high-precision AutoBalancerV2
    access(account) fun _initNewAutoBalancer(
        oracle: {DFB.PriceOracle},
        vaultType: Type,
        lowerThreshold: UFix64,
        upperThreshold: UFix64,
        rebalanceSink: {DFB.Sink}?,
        rebalanceSource: {DFB.Source}?,
        uniqueID: DFB.UniqueIdentifier
    ): auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFBv2.AutoBalancerV2 {

        // derive paths & prevent collision
        let storagePath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: true) as! StoragePath
        let publicPath = self.deriveAutoBalancerPath(id: uniqueID.id, storage: false) as! PublicPath
        var storedType = self.account.storage.type(at: storagePath)
        var publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == nil,
            message: "Storage collision when creating AutoBalancerV2 for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(!publishedCap,
            message: "Published Capability collision found when publishing AutoBalancerV2 for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")

        // create & save AutoBalancerV2
        let autoBalancer <- DFBv2.createAutoBalancerV2(
                oracle: oracle,
                vault: <- DFBUtils.getEmptyVault(vaultType),
                rebalanceRange: [lowerThreshold, upperThreshold],
                rebalanceSink: rebalanceSink,
                rebalanceSource: rebalanceSource,
                uniqueID: uniqueID
            )
        self.account.storage.save(<-autoBalancer, to: storagePath)
        let autoBalancerRef = self._borrowAutoBalancer(uniqueID.id)

        // issue & publish public capability
        let publicCap = self.account.capabilities.storage.issue<&DFBv2.AutoBalancerV2>(storagePath)
        self.account.capabilities.publish(publicCap, at: publicPath)

        // issue private capability & set within AutoBalancer
        let authorizedCap = self.account.capabilities.storage.issue<auth(FungibleToken.Withdraw) &DFBv2.AutoBalancerV2>(storagePath)
        autoBalancerRef.setSelfCapability(authorizedCap)

        // ensure proper configuration before closing
        storedType = self.account.storage.type(at: storagePath)
        publishedCap = self.account.capabilities.exists(publicPath)
        assert(storedType == Type<@DFBv2.AutoBalancerV2>(),
            message: "Error when configuring AutoBalancerV2 for UniqueIdentifier.id \(uniqueID.id) at path \(storagePath)")
        assert(publishedCap,
            message: "Error when publishing AutoBalancerV2 Capability for UniqueIdentifier.id \(uniqueID.id) at path \(publicPath)")
        return autoBalancerRef
    }

    /// Returns an authorized reference to the AutoBalancerV2
    access(account)
    fun _borrowAutoBalancer(_ id: UInt64): auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFBv2.AutoBalancerV2 {
        let storagePath = self.deriveAutoBalancerPath(id: id, storage: true) as! StoragePath
        return self.account.storage.borrow<auth(DFB.Auto, DFB.Set, DFB.Get, FungibleToken.Withdraw) &DFBv2.AutoBalancerV2>(
                from: storagePath
            ) ?? panic("Could not borrow reference to AutoBalancerV2 with UniqueIdentifier.id \(id) from StoragePath \(storagePath)")
    }

    /// Cleans up an AutoBalancerV2 when a Strategy is burned
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
        let autoBalancer <-self.account.storage.load<@DFBv2.AutoBalancerV2>(from: storagePath)
        Burner.burn(<-autoBalancer)
    }

    init() {
        self.pathPrefix = "TidalYieldAutoBalancerV2_"
    }
} 