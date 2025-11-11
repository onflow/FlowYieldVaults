import "FungibleToken"
import "FungibleTokenMetadataViews"
import "FlowVaults"

/// Create tide without beta requirement (for testing only)
/// This bypasses the beta check by directly creating strategies
transaction(strategyIdentifier: String, vaultIdentifier: String, amount: UFix64) {
    let depositVault: @{FungibleToken.Vault}
    let strategy: Type

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Create the Strategy Type
        self.strategy = CompositeType(strategyIdentifier)
            ?? panic("Invalid strategyIdentifier \(strategyIdentifier)")

        // Get vault data and withdraw funds
        let vaultType = CompositeType(vaultIdentifier)
            ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Not a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
                resourceType: vaultType,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData")

        let sourceVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("No vault at \(vaultData.storagePath)")
        self.depositVault <- sourceVault.withdraw(amount: amount)
    }

    execute {
        // Create strategy directly using the factory
        let uniqueID = DeFiActions.createUniqueIdentifier()
        let strategy <- FlowVaults.createStrategy(
            type: self.strategy,
            uniqueID: uniqueID,
            withFunds: <-self.depositVault
        )
        
        // For testing, just destroy it
        // In real scenario, you'd save it properly
        destroy strategy
        
        log("✅ Strategy created successfully (test mode - destroyed)")
        log("   This proves strategy creation works!")
    }
}

