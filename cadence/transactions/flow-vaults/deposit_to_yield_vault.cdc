import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

import "FlowVaults"
import "FlowVaultsClosedBeta"

/// Deposits to an existing YieldVault stored in the signer's YieldVaultManager
///
/// @param id: The YieldVault.id() of the YieldVault to which the amount will be deposited
/// @param amount: The amount to deposit into the new YieldVault, denominated in the YieldVault's Vault type
///
transaction(id: UInt64, amount: UFix64) {
    let manager: &FlowVaults.YieldVaultManager
    let depositVault: @{FungibleToken.Vault}
    let betaRef: auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(from: FlowVaultsClosedBeta.UserBetaCapStoragePath)
            ?? panic("Signer does not have a BetaBadge stored at path \(FlowVaultsClosedBeta.UserBetaCapStoragePath) - configure and retry")

        self.betaRef = betaCap.borrow()
            ?? panic("Capability does not contain correct reference")
 
        // reference the signer's YieldVaultManager & underlying YieldVault
        self.manager = signer.storage.borrow<&FlowVaults.YieldVaultManager>(from: FlowVaults.YieldVaultManagerStoragePath)
            ?? panic("Signer does not have a YieldVaultManager stored at path \(FlowVaults.YieldVaultManagerStoragePath) - configure and retry")
        let yieldVault = self.manager.borrowYieldVault(id: id) ?? panic("YieldVault with ID \(id) was not found")

        // get the data for where the vault type is canoncially stored
        let vaultType = yieldVault.getSupportedVaultTypes().keys[0]
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Vault type \(vaultType.identifier) is not defined by a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for vault type \(vaultType.identifier)")

        // withdraw the amount to deposit into the new YieldVault
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Signer does not have a vault of type \(vaultType.identifier) at path \(vaultData.storagePath) from which to source funds")
        self.depositVault <- sourceVault.withdraw(amount: amount)
    }

    execute {
        self.manager.depositToYieldVault(betaRef: self.betaRef, id, from: <-self.depositVault)
    }
}
