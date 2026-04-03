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
        let storagePath = /storage/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault

        self.vault <- (sender.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(from: storagePath)
            ?? panic("Sender has no PYUSD0 vault")).withdraw(amount: amount)

        // Set up receiver's PYUSD0 vault if not present
        if rcvr.storage.borrow<&{FungibleToken.Vault}>(from: storagePath) == nil {
            let pyusd0Type = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!
            let vaultData = getAccount(pyusd0Type.address!).contracts.borrow<&{ViewResolver}>(name: pyusd0Type.contractName!)!
                .resolveContractView(resourceType: pyusd0Type, viewType: Type<FungibleTokenMetadataViews.FTVaultData>())
                as! FungibleTokenMetadataViews.FTVaultData?
                ?? panic("Could not resolve FTVaultData for PYUSD0")
            rcvr.storage.save(<-vaultData.createEmptyVault(), to: storagePath)
            rcvr.capabilities.unpublish(vaultData.receiverPath)
            rcvr.capabilities.unpublish(vaultData.metadataPath)
            rcvr.capabilities.publish(rcvr.capabilities.storage.issue<&{FungibleToken.Vault}>(storagePath), at: vaultData.receiverPath)
            rcvr.capabilities.publish(rcvr.capabilities.storage.issue<&{FungibleToken.Vault}>(storagePath), at: vaultData.metadataPath)
        }
        self.receiver = rcvr.storage.borrow<&{FungibleToken.Vault}>(from: storagePath)
            ?? panic("Could not borrow receiver PYUSD0 vault")
    }

    execute {
        self.receiver.deposit(from: <-self.vault)
        log("Transferred ".concat(amount.toString()).concat(" PYUSD0 to receiver"))
    }
}
