access(all) contract FlowYieldVaultsClosedBeta {

    access(all) entitlement Admin
    access(all) entitlement Beta

    access(all) resource BetaBadge {
        access(all) let assignedTo: Address
        init(_ addr: Address) {
            self.assignedTo = addr
        }
        access(all) view fun getOwner(): Address {
            return self.assignedTo
        }
    }

    // --- Paths ---
    access(all) let UserBetaCapStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath

    // --- Registry: which capability was issued to which address, and revocation flags ---
    access(all) struct AccessInfo {
        access(all) let capID: UInt64
        access(all) let isRevoked: Bool

        init(_ capID: UInt64, _ isRevoked: Bool) {
            self.capID = capID
            self.isRevoked = isRevoked
        }
    }
    access(all) var issuedCapIDs: {Address: AccessInfo}

    // --- Events ---
    access(all) event BetaGranted(addr: Address, capID: UInt64)
    access(all) event BetaRevoked(addr: Address, capID: UInt64?)

    /// Per-user badge storage path (under the *contract/deployer* account)
    access(contract) fun _badgePath(_ addr: Address): StoragePath {
        return StoragePath(identifier: "FlowYieldVaultsBetaBadge_".concat(addr.toString()))!
    }

    /// Ensure the admin-owned badge exists for the user
    access(contract) fun _ensureBadge(_ addr: Address) {
        let p = self._badgePath(addr)
        if self.account.storage.type(at: p) == nil {
            self.account.storage.save(<-create BetaBadge(addr), to: p)
        }
    }

    access(contract) fun _destroyBadge(_ addr: Address) {
        let p = self._badgePath(addr)
        if let badge <- self.account.storage.load<@BetaBadge>(from: p) {
            destroy badge
        }
    }

    /// Issue a capability from the contract/deployer account and record its ID
    access(contract) fun _issueBadgeCap(_ addr: Address): Capability<auth(Beta) &BetaBadge> {
        let p = self._badgePath(addr)
        let cap: Capability<auth(Beta) &BetaBadge> =
            self.account.capabilities.storage.issue<auth(Beta) &BetaBadge>(p)

        self.issuedCapIDs[addr] = AccessInfo(cap.id, false)

        if let ctrl = self.account.capabilities.storage.getController(byCapabilityID: cap.id) {
            ctrl.setTag("flowyieldvaults-beta")
        }

        emit BetaGranted(addr: addr, capID: cap.id)
        return cap
    }

    /// Delete the recorded controller, revoking *all copies* of the capability
    access(contract) fun _revokeByAddress(_ addr: Address) {
        let info = self.issuedCapIDs[addr] ?? panic("No cap recorded for address")
        let ctrl = self.account.capabilities.storage.getController(byCapabilityID: info.capID)
            ?? panic("Missing controller for recorded cap ID")
        ctrl.delete()
        self.issuedCapIDs[addr] = AccessInfo(info.capID, true)
        self._destroyBadge(addr)
        emit BetaRevoked(addr: addr, capID: info.capID)
    }

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(addr: Address): Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> {
            FlowYieldVaultsClosedBeta._ensureBadge(addr)
            return FlowYieldVaultsClosedBeta._issueBadgeCap(addr)
        }

        access(Admin) fun revokeByAddress(addr: Address) {
            FlowYieldVaultsClosedBeta._revokeByAddress(addr)
        }
    }

    /// Read-only check used by any gated entrypoint
    access(all) view fun getBetaCapID(_ addr: Address): UInt64? {
        if let info = self.issuedCapIDs[addr] {
            if info.isRevoked {
                assert(info.isRevoked, message: "Beta access revoked") 
                return nil
            }
            return info.capID
        }
        return nil
    }

    access(all) view fun validateBeta(_ addr: Address?, _ betaRef: auth(Beta) &BetaBadge): Bool {
        if (addr == nil) {
            assert(addr == nil, message: "Address is required for Beta verification") 
            return false
        }
        let recordedID: UInt64? = self.getBetaCapID(addr!); 
        if recordedID == nil {
            assert(recordedID == nil, message: "No Beta access") 
            return false
        }

        if betaRef.getOwner() != addr {
            assert(betaRef.getOwner() != addr, message: "BetaBadge may only be used by its assigned owner") 
            return false
        }

        return true 
    }

    init() {
        self.AdminHandleStoragePath = StoragePath(
            identifier: "FlowYieldVaultsClosedBetaAdmin_\(self.account.address)"
        )!
        self.UserBetaCapStoragePath = StoragePath(
            identifier: "FlowYieldVaultsUserBetaCap_\(self.account.address)"
        )!

        self.issuedCapIDs = {}

        // Create and store the admin handle in *this* (deployer) account
        self.account.storage.save(<-create AdminHandle(), to: self.AdminHandleStoragePath)
    }
}
