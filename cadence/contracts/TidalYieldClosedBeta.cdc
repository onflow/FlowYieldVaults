access(all) contract TidalYieldClosedBeta {

    // 1) Define an entitlement only the admin can issue
    access(all) entitlement Admin

    access(all) resource interface IBeta {}
    access(all) resource BetaBadge: IBeta {}

    // --- Paths ---
    access(all) let UserBetaCapStoragePath: StoragePath
    access(all) let BetaBadgeStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath
    access(all) let BetaBadgePublicPath: PublicPath

    // --- Registry: which capability was issued to which address, and revocation flags ---
    access(all) var issuedCapIDs: {Address: UInt64}

    // --- Events ---
    access(all) event BetaGranted(addr: Address, capID: UInt64)
    access(all) event BetaRevoked(addr: Address, capID: UInt64?)

    /// Per-user badge storage path (under the *contract/deployer* account)
    access(contract) fun _badgePath(_ addr: Address): StoragePath {
        return StoragePath(identifier: "TY_BetaBadge_".concat(addr.toString()))!
    }

    /// Ensure the admin-owned badge exists for the user
    access(contract) fun _ensureBadge(_ addr: Address) {
        let p = self._badgePath(addr)
        if self.account.storage.type(at: p) == nil {
            self.account.storage.save(<-create BetaBadge(), to: p)
        }
    }

    /// Issue a capability from the contract/deployer account and record its ID
    access(contract) fun _issueBadgeCap(_ addr: Address): Capability<&{TidalYieldClosedBeta.IBeta}> {
        let p = self._badgePath(addr)
        let cap: Capability<&{TidalYieldClosedBeta.IBeta}> =
            self.account.capabilities.storage.issue<&{TidalYieldClosedBeta.IBeta}>(p)
        self.issuedCapIDs[addr] = cap.id

        if let ctrl = self.account.capabilities.storage.getController(byCapabilityID: cap.id) {
            ctrl.setTag("tidalyield-beta")
        }

        emit BetaGranted(addr: addr, capID: cap.id)
        return cap
    }

    /// Delete the recorded controller, revoking *all copies* of the capability
    access(contract) fun _revokeByAddress(_ addr: Address) {
        let id = self.issuedCapIDs[addr] ?? panic("No cap recorded for address")
        let ctrl = self.account.capabilities.storage.getController(byCapabilityID: id)
            ?? panic("Missing controller for recorded cap ID")
        ctrl.delete()
        self.issuedCapIDs.remove(key: addr)
        emit BetaRevoked(addr: addr, capID: id)
    }

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(addr: Address): Capability<&{TidalYieldClosedBeta.IBeta}> {
            TidalYieldClosedBeta._ensureBadge(addr)
            return TidalYieldClosedBeta._issueBadgeCap(addr)
        }

        access(Admin) fun revokeByAddress(addr: Address) {
            TidalYieldClosedBeta._revokeByAddress(addr)
        }
    }

    /// Read-only check used by any gated entrypoint
    access(all) view fun getBetaCapID(_ addr: Address): UInt64? {
        return self.issuedCapIDs[addr]
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
        self.UserBetaCapStoragePath = StoragePath(
            identifier: "TidalYieldUserBetaCap_\(self.account.address)"
        )!

        self.issuedCapIDs = {}

        // Create and store the admin handle in *this* (deployer) account
        self.account.storage.save(<-create AdminHandle(), to: self.AdminHandleStoragePath)
    }
}
