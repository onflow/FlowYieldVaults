access(all) contract FlowYieldVaultsClosedBeta {

    access(all) entitlement Admin
    access(all) entitlement Beta

    access(all) resource BetaBadge {
        access(all) let assignedTo: Address
        init(assignedTo: Address) {
            self.assignedTo = assignedTo
        }
    }

    // --- Paths ---
    access(all) let UserBetaCapStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath

    // --- Registry: which capability was issued to which address, and revocation flags ---
    access(all) struct AccessInfo {
        access(all) let capID: UInt64
        access(all) let isRevoked: Bool

        init(capID: UInt64, isRevoked: Bool) {
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
        return StoragePath(identifier: "FlowYieldVaultsBetaBadge_\(addr)")!
    }

    /// Ensure the admin-owned badge exists for the user
    access(contract) fun _ensureBadge(_ addr: Address) {
        let path = self._badgePath(addr)
        if self.account.storage.type(at: path) == nil {
            self.account.storage.save(<-create BetaBadge(assignedTo: addr), to: path)
        }
    }

    access(contract) fun _destroyBadge(_ addr: Address) {
        let path = self._badgePath(addr)
        if let badge <- self.account.storage.load<@BetaBadge>(from: path) {
            destroy badge
        }
    }

    /// Issue a capability from the contract/deployer account and record its ID
    access(contract) fun _issueBadgeCap(_ addr: Address): Capability<auth(Beta) &BetaBadge> {
        let path = self._badgePath(addr)
        let cap = self.account.capabilities.storage.issue<auth(Beta) &BetaBadge>(path)

        self.issuedCapIDs[addr] = AccessInfo(capID: cap.id, isRevoked: false)

        if let ctrl = self.account.capabilities.storage.getController(byCapabilityID: cap.id) {
            ctrl.setTag("flowyieldvaults-beta")
        }

        emit BetaGranted(addr: addr, capID: cap.id)
        return cap
    }

    /// Clean up any previously issued controller before issuing a fresh capability.
    access(contract) fun _cleanupExistingGrant(_ addr: Address) {
        if let info = self.issuedCapIDs[addr] {
            if let ctrl = self.account.capabilities.storage.getController(byCapabilityID: info.capID) {
                ctrl.delete()
                emit BetaRevoked(addr: addr, capID: info.capID)
            }
        }
    }

    /// Delete the recorded controller, revoking *all copies* of the capability
    access(contract) fun _revokeByAddress(_ addr: Address) {
        let info = self.issuedCapIDs[addr] ?? panic("No cap recorded for address")
        let ctrl = self.account.capabilities.storage.getController(byCapabilityID: info.capID)
            ?? panic("Missing controller for recorded cap ID")
        ctrl.delete()
        self.issuedCapIDs[addr] = AccessInfo(capID: info.capID, isRevoked: true)
        self._destroyBadge(addr)
        emit BetaRevoked(addr: addr, capID: info.capID)
    }

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(addr: Address): Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge> {
            FlowYieldVaultsClosedBeta._cleanupExistingGrant(addr)
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
        let recordedID = self.getBetaCapID(addr!)
        assert(recordedID != nil, message: "No Beta access")

        assert(betaRef.assignedTo == addr, message: "BetaBadge may only be used by its assigned owner")

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
