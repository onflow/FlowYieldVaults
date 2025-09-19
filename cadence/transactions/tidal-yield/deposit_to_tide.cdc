import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "TidalYield"
import "TidalYieldClosedBeta"

/// Deposits to an existing Tide stored in the signer's TideManager
///
/// @param id: The Tide.id() of the Tide to which the amount will be deposited
/// @param amount: The amount to deposit into the new Tide, denominated in the Tide's Vault type
///
transaction(id: UInt64, amount: UFix64) {
    let manager: &TidalYield.TideManager
    let depositVault: @{FungibleToken.Vault}
    let betaRef: auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>>(from: TidalYieldClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer doesn not have a BetaBadge stored at path \(TidalYieldClosedBeta.UserBetaCapStoragePath) - configure and retry")

        self.betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")
 
        // reference the signer's TideManager & underlying Tide
        self.manager = signer.storage.borrow<&TidalYield.TideManager>(from: TidalYield.TideManagerStoragePath)
            ?? panic("Signer does not have a TideManager stored at path \(TidalYield.TideManagerStoragePath) - configure and retry")
        let tide = self.manager.borrowTide(id: id) ?? panic("Tide with ID \(id) was not found")

        // get the data for where the vault type is canoncially stored
        let vaultType = tide.getSupportedVaultTypes().keys[0]
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Vault type \(vaultType.identifier) is not defined by a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for vault type \(vaultType.identifier)")

        // withdraw the amount to deposit into the new Tide
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Signer does not have a vault of type \(vaultType.identifier) at path \(vaultData.storagePath) from which to source funds")
        self.depositVault <- sourceVault.withdraw(amount: amount)
    }

    execute {
        self.manager.depositToTide(betaRef: self.betaRef, id, from: <-self.depositVault)
    }
}
