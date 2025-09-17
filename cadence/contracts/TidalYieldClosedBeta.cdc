access(all) contract TidalYieldClosedBeta {

    // 1) Define an entitlement only the admin can issue
    access(all) entitlement Admin

    access(all) resource interface IBeta {}
    access(all) resource BetaBadge: IBeta {}

    // --- Paths ---
    access(all) let BetaBadgeStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath
    access(all) let BetaBadgePublicPath: PublicPath

    // --- Registry: which capability was issued to which address, and revocation flags ---
    access(all) var issuedCapIDs: {Address: UInt64}

    // --- Events ---
    access(all) event BetaGranted(addr: Address, capID: UInt64)
    access(all) event BetaRevoked(addr: Address, capID: UInt64?)

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(addr: Address): Capability<&{TidalYieldClosedBeta.BetaBadge}> {
            // Store a badge under a path derived from the user address, but in ADMIN storage
            let path = StoragePath(identifier: "TY_BetaBadge_".concat(addr.toString()))!
            // create only once
            if self.account.storage.type(at: path) == nil {
                self.account.storage.save(<-create TidalYieldClosedBeta.BetaBadge(addr), to: path)
            }
            // Issue a capability FROM ADMIN (controller in admin)
            let cap: Capability<&{TidalYieldClosedBeta.BetaBadge}> =
                self.account.capabilities.storage.issue<&{TidalYieldClosedBeta.BetaBadge}>(path)
            TidalYieldClosedBeta.issuedCapIDs[addr] = cap.id

            return cap
        }

        access(Admin) fun revokeByAddress(addr: Address) {
            let id = TidalYieldClosedBeta.issuedCapIDs[addr] ?? panic("No cap recorded")
            let ctrl = self.account.capabilities.storage.getController(byCapabilityID: id)
                ?? panic("Missing controller")
            ctrl.delete()
            TidalYieldClosedBeta.issuedCapIDs.remove(key: addr)
        }
    }

    init() {
        self.BetaBadgeStoragePath = StoragePath(
            identifier: "TidalYieldBetaBadge_\(self.account.address)"
        )!
        self.AdminHandleStoragePath = StoragePath(
            identifier: "TidalYieldClosedBetaAdmin_\(self.account.address)"
        )!
        self.BetaBadgePublicPath = PublicPath(
            identifier: "TidalYieldBetaBadge_\(self.account.address)"
        )!

        self.issuedCapIDs = {}

        // Create and store the admin handle in *this* (deployer) account
        self.account.storage.save(<-create AdminHandle(), to: self.AdminHandleStoragePath)
    }
}
