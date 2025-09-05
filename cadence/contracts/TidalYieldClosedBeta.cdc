access(all) contract TidalYieldClosedBeta {

    // 1) Define an entitlement only the admin can issue
    access(all) entitlement Admin

    access(all) resource interface IBeta {}
    access(all) resource BetaBadge: IBeta {}

    access(all) let BetaBadgeStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(to: auth(Storage) &Account) {
            pre {
                to.storage.type(at: TidalYieldClosedBeta.BetaBadgeStoragePath) == nil:
                    "BetaBadge already exists for this account"
            }
            to.storage.save(<-create BetaBadge(), to: TidalYieldClosedBeta.BetaBadgeStoragePath)
        }
        access(Admin) fun revokeBeta(from: auth(Storage) &Account) {
            pre {
                from.storage.type(at: TidalYieldClosedBeta.BetaBadgeStoragePath) != nil:
                    "No BetaBadge to revoke"
            }
            let badge <- from.storage.load<@BetaBadge>(from: TidalYieldClosedBeta.BetaBadgeStoragePath)
                ?? panic("Missing BetaBadge")
            destroy badge
        }
    }

    init() {
        self.BetaBadgeStoragePath = StoragePath(
            identifier: "TidalYieldBetaBadge_\(self.account.address)"
        )!
        self.AdminHandleStoragePath = StoragePath(
            identifier: "TidalYieldClosedBetaAdmin_\(self.account.address)"
        )!

        // Create and store the admin handle in *this* (deployer) account
        self.account.storage.save(<-create AdminHandle(), to: self.AdminHandleStoragePath)
    }
}
