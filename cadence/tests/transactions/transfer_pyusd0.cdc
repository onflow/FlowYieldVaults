import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

/// Transfers PYUSD0 from the first signer (sender) to the second signer (receiver).
/// Sets up the receiver's PYUSD0 Cadence vault if it is not already present.
///
/// Used in tests to provision PYUSD0 to accounts that have a COA but no PYUSD0,
/// avoiding the need for an EVM swap.
///
/// @param amount: PYUSD0 amount (UFix64) to transfer
transaction(amount: UFix64) {

    let vault: @{FungibleToken.Vault}
    let receiver: &{FungibleToken.Vault}

    prepare(
        sender: auth(BorrowValue) &Account,
        rcvr: auth(Storage, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account
    ) {
        let pyusd0Type = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!
        let viewResolver = getAccount(pyusd0Type.address!).contracts.borrow<&{ViewResolver}>(name: pyusd0Type.contractName!)
            ?? panic("Could not borrow ViewResolver for PYUSD0")
        let vaultData = viewResolver.resolveContractView(
            resourceType: pyusd0Type,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for PYUSD0")

        // Withdraw from sender
        let senderVault = sender.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            from: vaultData.storagePath
        ) ?? panic("Sender has no PYUSD0 vault at ".concat(vaultData.storagePath.toString()))
        self.vault <- senderVault.withdraw(amount: amount)

        // Set up receiver's PYUSD0 vault if not present
        if rcvr.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath) == nil {
            rcvr.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
            rcvr.capabilities.unpublish(vaultData.receiverPath)
            rcvr.capabilities.unpublish(vaultData.metadataPath)
            let receiverCap = rcvr.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            let metadataCap = rcvr.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            rcvr.capabilities.publish(receiverCap, at: vaultData.receiverPath)
            rcvr.capabilities.publish(metadataCap, at: vaultData.metadataPath)
        }
        self.receiver = rcvr.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Could not borrow receiver PYUSD0 vault")
    }

    execute {
        self.receiver.deposit(from: <-self.vault)
        log("Transferred ".concat(amount.toString()).concat(" PYUSD0 to receiver"))
    }
}
