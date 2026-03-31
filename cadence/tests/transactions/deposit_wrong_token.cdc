import "FungibleToken"
import "FungibleTokenMetadataViews"

import "FlowYieldVaults"
import "FlowYieldVaultsClosedBeta"

/// Test-only transaction: attempts to deposit a token of the wrong type into an existing YieldVault.
/// The strategy's pre-condition should reject the mismatched vault type and cause this to fail.
///
/// @param vaultID: The YieldVault to deposit into
/// @param wrongTokenTypeIdentifier: Type identifier of the wrong token to deposit
/// @param amount: Amount to withdraw from the signer's storage and attempt to deposit
///
transaction(vaultID: UInt64, wrongTokenTypeIdentifier: String, amount: UFix64) {
    let manager: &FlowYieldVaults.YieldVaultManager
    let depositVault: @{FungibleToken.Vault}
    let betaRef: auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge

    prepare(signer: auth(BorrowValue, CopyValue) &Account) {
        let betaCap = signer.storage.copy<Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>>(
            from: FlowYieldVaultsClosedBeta.UserBetaCapStoragePath
        ) ?? panic("Signer does not have a BetaBadge")
        self.betaRef = betaCap.borrow() ?? panic("BetaBadge capability is invalid")

        self.manager = signer.storage.borrow<&FlowYieldVaults.YieldVaultManager>(
            from: FlowYieldVaults.YieldVaultManagerStoragePath
        ) ?? panic("Signer does not have a YieldVaultManager")

        let wrongType = CompositeType(wrongTokenTypeIdentifier)
            ?? panic("Invalid type identifier \(wrongTokenTypeIdentifier)")
        let tokenContract = getAccount(wrongType.address!).contracts.borrow<&{FungibleToken}>(name: wrongType.contractName!)
            ?? panic("Type \(wrongTokenTypeIdentifier) is not a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
            resourceType: wrongType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("No FTVaultData for type \(wrongTokenTypeIdentifier)")
        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: vaultData.storagePath
        ) ?? panic("Signer has no vault of type \(wrongTokenTypeIdentifier) at path \(vaultData.storagePath)")

        self.depositVault <- sourceVault.withdraw(amount: amount)
    }

    execute {
        self.manager.depositToYieldVault(betaRef: self.betaRef, vaultID, from: <-self.depositVault)
    }
}
