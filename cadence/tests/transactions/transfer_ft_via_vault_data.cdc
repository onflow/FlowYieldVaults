import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

/// Generic FungibleToken transfer that resolves storage/receiver paths via FTVaultData.
/// Works with any FT implementing FungibleTokenMetadataViews (including EVMVMBridgedTokens).
///
/// @param contractAddress  Address of the token contract (e.g. 0x1e4aa0b87d10b141)
/// @param contractName     Name of the token contract  (e.g. EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750)
/// @param amount           Amount to transfer
/// @param to               Recipient Cadence address (must already have receiver capability published)

transaction(contractAddress: Address, contractName: String, amount: UFix64, to: Address) {

    let sentVault: @{FungibleToken.Vault}
    let receiverPath: PublicPath

    prepare(signer: auth(BorrowValue) &Account) {
        let viewResolver = getAccount(contractAddress).contracts.borrow<&{ViewResolver}>(name: contractName)
            ?? panic("Cannot borrow ViewResolver for ".concat(contractName))

        let vaultData = viewResolver.resolveContractView(
            resourceType: nil,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Cannot resolve FTVaultData for ".concat(contractName))

        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: vaultData.storagePath
        ) ?? panic("Cannot borrow vault from ".concat(vaultData.storagePath.toString()))

        self.sentVault <- vaultRef.withdraw(amount: amount)
        self.receiverPath = vaultData.receiverPath
    }

    execute {
        let receiverRef = getAccount(to).capabilities.borrow<&{FungibleToken.Receiver}>(self.receiverPath)
            ?? panic("Cannot borrow receiver at ".concat(self.receiverPath.toString()))
        receiverRef.deposit(from: <-self.sentVault)
    }
}
