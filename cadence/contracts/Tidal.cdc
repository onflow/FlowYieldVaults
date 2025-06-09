import "FungibleToken"
import "Burner"
import "ViewResolver"

import "DFB"
import "TidalStrategies"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract Tidal {

    access(all) let TideManagerStoragePath: StoragePath
    access(all) let TideManagerPublicPath: PublicPath

    access(all) event CreatedTide(id: UInt64, idType: String, uuid: UInt64, initialAmount: UFix64, creator: Address?)
    access(all) event DepositedToTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, fromUUID: UInt64)
    access(all) event WithdrawnFromTide(id: UInt64, idType: String, amount: UFix64, owner: Address?, toUUID: UInt64)
    access(all) event AddedToManager(id: UInt64, idType: String, owner: Address?, managerUUID: UInt64)
    access(all) event BurnedTide(id: UInt64, idType: String, remainingBalance: UFix64)

    access(all) fun createTideManager(): @TideManager {
        return <-create TideManager()
    }

    /* --- CONSTRUCTS --- */

    access(all) resource Tide : Burner.Burnable, FungibleToken.Receiver, ViewResolver.Resolver {
        access(contract) let uniqueID: DFB.UniqueIdentifier
        access(self) let strategy: {TidalStrategies.Strategy}

        init(strategyNumber: UInt64, withVault: @{FungibleToken.Vault}) {
            pre {
                TidalStrategies.isSupportedCollateralType(withVault.getType(), forStrategy: strategyNumber) == true:
                "Provided vault of type \(withVault.getType().identifier) is unsupported collateral Type for strategy \(strategyNumber)"
            }
            self.uniqueID = DFB.UniqueIdentifier()
            let vaultType = withVault.getType()
            self.strategy = TidalStrategies.createStrategy(number: strategyNumber, vault: <-withVault)
            assert(self.strategy.getSinkType() == vaultType, message: "TODO")
            assert(self.strategy.getSourceType() == vaultType, message: "TODO")
        }

        access(all) view fun id(): UInt64 {
            return self.uniqueID!.id
        }

        access(all) fun getTideBalance(): UFix64 {
            return self.strategy.minimumAvailable()
        }

        access(contract) fun burnCallback() {
            emit BurnedTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, remainingBalance: self.getTideBalance())
        }

        access(all) view fun getViews(): [Type] {
            return []
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return nil
        }

        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                self.isSupportedVaultType(type: from.getType()):
                "Deposited vault of type \(from.getType().identifier) is not supported by this Tide"
            }
            emit DepositedToTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: from.balance, owner: self.owner?.address, fromUUID: from.uuid)
            self.strategy.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            assert(from.balance == 0.0, message: "TODO")
            Burner.burn(<-from)
        }

        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            return { self.strategy.getSinkType(): true }
        }

        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return self.getSupportedVaultTypes()[type] ?? false
        }

        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
            post {
                result.balance == amount: "TODO"
            }
            let available = self.strategy.minimumAvailable()
            assert(
                amount <= available,
                message: "Requested amount \(amount) is greater than withdrawable balance of \(available)"
            )
            let res <- self.strategy.withdrawAvailable(maxAmount: amount)
            emit WithdrawnFromTide(id: self.uniqueID.id, idType: self.uniqueID.getType().identifier, amount: amount, owner: self.owner?.address, toUUID: res.uuid)
            return <- res
        }
    }

    access(all) entitlement Owner

    access(all) resource TideManager : ViewResolver.ResolverCollection {
        access(self) let tides: @{UInt64: Tide}

        init() {
            self.tides <- {}
        }

        access(all) view fun borrowTide(id: UInt64): &Tide? {
            return &self.tides[id]
        }

        access(all) view fun borrowViewResolver(id: UInt64): &{ViewResolver.Resolver}? {
            return &self.tides[id]
        }

        access(all) view fun getIDs(): [UInt64] {
            return self.tides.keys
        }

        access(all) view fun getNumberOfTides(): Int {
            return self.tides.length
        }

        access(all) fun createTide(withVault: @{FungibleToken.Vault}) {
            let balance = withVault.balance
            let tide <-create Tide(<-withVault)

            emit CreatedTide(id: tide.uniqueID!.id, idType: tide.uniqueID!.getType().identifier, uuid: tide.uuid, initialAmount: balance, creator: self.owner?.address)

            self.addTide(<-tide)
        }

        access(all) fun addTide(_ tide: @Tide) {
            pre {
                self.tides[tide.uniqueID!.id] == nil:
                "Collision with Tide ID \(tide.uniqueID!.id) - a Tide with this ID already exists"
            }
            emit AddedToManager(id: tide.uniqueID!.id, idType: tide.uniqueID!.getType().identifier, owner: self.owner?.address, managerUUID: self.uuid)
            self.tides[tide.uniqueID!.id] <-! tide
        }

        access(all) fun depositToTide(_ id: UInt64, from: @{FungibleToken.Vault}) {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as &Tide?)!
            tide.deposit(from: <-from)
        }

        access(Owner) fun withdrawTide(id: UInt64): @Tide {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            return <- self.tides.remove(key: id)!
        }

        access(Owner) fun withdrawFromTide(_ id: UInt64, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide = (&self.tides[id] as auth(FungibleToken.Withdraw) &Tide?)!
            return <- tide.withdraw(amount: amount)
        }

        access(Owner) fun closeTide(_ id: UInt64): @{FungibleToken.Vault} {
            pre {
                self.tides[id] != nil:
                "No Tide with ID \(id) found"
            }
            let tide <- self.withdrawTide(id: id)
            let res <- tide.withdraw(amount: tide.getTideBalance())
            Burner.burn(<-tide)
            return <-res
        }
    }

    init() {
        let pathIdentifier = "TidalTideManager_\(self.account.address)"
        self.TideManagerStoragePath = StoragePath(identifier: pathIdentifier)!
        self.TideManagerPublicPath = PublicPath(identifier: pathIdentifier)!
    }
}
