import "FungibleToken"
import "MetadataViews"
import "FungibleTokenMetadataViews"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MOET : FungibleToken {

    /// Total supply of MOET in existence
    access(all) var totalSupply: UFix64

    /// Storage and Public Paths
    access(all) let VaultStoragePath: StoragePath
    access(all) let VaultPublicPath: PublicPath
    access(all) let ReceiverPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath

    /// The event that is emitted when new tokens are minted
    access(all) event Minted(type: String, amount: UFix64, toUUID: UInt64, minterUUID: UInt64)
    /// Emitted whenever a new Minter is created
    access(all) event MinterCreated(uuid: UInt64)

    /// createEmptyVault
    ///
    /// Function that creates a new Vault with a balance of zero
    /// and returns it to the calling context. A user must call this function
    /// and store the returned Vault in their storage in order to allow their
    /// account to be able to receive deposits of this token type.
    ///
    access(all) fun createEmptyVault(vaultType: Type): @MOET.Vault {
        return <- create Vault(balance: 0.0)
    }

    access(all) view fun getContractViews(resourceType: Type?): [Type] {
        return [
            Type<FungibleTokenMetadataViews.FTView>(),
            Type<FungibleTokenMetadataViews.FTDisplay>(),
            Type<FungibleTokenMetadataViews.FTVaultData>(),
            Type<FungibleTokenMetadataViews.TotalSupply>()
        ]
    }

    access(all) fun resolveContractView(resourceType: Type?, viewType: Type): AnyStruct? {
        switch viewType {
            case Type<FungibleTokenMetadataViews.FTView>():
                return FungibleTokenMetadataViews.FTView(
                    ftDisplay: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTDisplay>()) as! FungibleTokenMetadataViews.FTDisplay?,
                    ftVaultData: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTVaultData>()) as! FungibleTokenMetadataViews.FTVaultData?
                )
            case Type<FungibleTokenMetadataViews.FTDisplay>():
                let media = MetadataViews.Media(
                        file: MetadataViews.HTTPFile(
                        url: "https://assets.website-files.com/5f6294c0c7a8cdd643b1c820/5f6294c0c7a8cda55cb1c936_Flow_Wordmark.svg"
                    ),
                    mediaType: "image/svg+xml"
                )
                let medias = MetadataViews.Medias([media])
                return FungibleTokenMetadataViews.FTDisplay(
                    name: "TidalProtocol USD",
                    symbol: "MOET",
                    description: "A mocked version of TidalProtocol stablecoin",
                    externalURL: MetadataViews.ExternalURL("https://flow.com"),
                    logos: medias,
                    socials: {
                        "twitter": MetadataViews.ExternalURL("https://twitter.com/flow_blockchain")
                    }
                )
            case Type<FungibleTokenMetadataViews.FTVaultData>():
                return FungibleTokenMetadataViews.FTVaultData(
                    storagePath: self.VaultStoragePath,
                    receiverPath: self.ReceiverPublicPath,
                    metadataPath: self.VaultPublicPath,
                    receiverLinkedType: Type<&MOET.Vault>(),
                    metadataLinkedType: Type<&MOET.Vault>(),
                    createEmptyVaultFunction: (fun(): @{FungibleToken.Vault} {
                        return <-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
                    })
                )
            case Type<FungibleTokenMetadataViews.TotalSupply>():
                return FungibleTokenMetadataViews.TotalSupply(
                    totalSupply: MOET.totalSupply
                )
        }
        return nil
    }

    /* --- CONSTRUCTS --- */

    /// Vault
    ///
    /// Each user stores an instance of only the Vault in their storage
    /// The functions in the Vault and governed by the pre and post conditions
    /// in FungibleToken when they are called.
    /// The checks happen at runtime whenever a function is called.
    ///
    /// Resources can only be created in the context of the contract that they
    /// are defined in, so there is no way for a malicious user to create Vaults
    /// out of thin air. A special Minter resource needs to be defined to mint
    /// new tokens.
    ///
    access(all) resource Vault: FungibleToken.Vault {

        /// The total balance of this vault
        access(all) var balance: UFix64

        /// Identifies the destruction of a Vault even when destroyed outside of Buner.burn() scope
        access(all) event ResourceDestroyed(uuid: UInt64 = self.uuid, balance: UFix64 = self.balance)

        init(balance: UFix64) {
            self.balance = balance
        }

        /// Called when a fungible token is burned via the `Burner.burn()` method
        access(contract) fun burnCallback() {
            if self.balance > 0.0 {
                MOET.totalSupply = MOET.totalSupply - self.balance
            }
            self.balance = 0.0
        }

        access(all) view fun getViews(): [Type] {
            return MOET.getContractViews(resourceType: nil)
        }

        access(all) fun resolveView(_ view: Type): AnyStruct? {
            return MOET.resolveContractView(resourceType: nil, viewType: view)
        }

        access(all) view fun getSupportedVaultTypes(): {Type: Bool} {
            let supportedTypes: {Type: Bool} = {}
            supportedTypes[self.getType()] = true
            return supportedTypes
        }

        access(all) view fun isSupportedVaultType(type: Type): Bool {
            return self.getSupportedVaultTypes()[type] ?? false
        }

        access(all) view fun isAvailableToWithdraw(amount: UFix64): Bool {
            return amount <= self.balance
        }

        access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @MOET.Vault {
            self.balance = self.balance - amount
            return <-create Vault(balance: amount)
        }

        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let vault <- from as! @MOET.Vault
            let amount = vault.balance
            vault.balance = 0.0
            destroy vault

            self.balance = self.balance + amount
        }

        access(all) fun createEmptyVault(): @MOET.Vault {
            return <-create Vault(balance: 0.0)
        }
    }

    /// Minter
    ///
    /// Resource object that token admin accounts can hold to mint new tokens.
    ///
    access(all) resource Minter {
        /// Identifies when a Minter is destroyed, coupling with MinterCreated event to trace Minter UUIDs
        access(all) event ResourceDestroyed(uuid: UInt64 = self.uuid)

        init() {
            emit MinterCreated(uuid: self.uuid)
        }

        /// mintTokens
        ///
        /// Function that mints new tokens, adds them to the total supply,
        /// and returns them to the calling context.
        ///
        access(all) fun mintTokens(amount: UFix64): @MOET.Vault {
            MOET.totalSupply = MOET.totalSupply + amount
            let vault <-create Vault(balance: amount)
            emit Minted(type: vault.getType().identifier, amount: amount, toUUID: vault.uuid, minterUUID: self.uuid)
            return <-vault
        }
    }

    init(initialMint: UFix64) {
        
        self.totalSupply = 0.0
        
        let address = self.account.address
        self.VaultStoragePath = StoragePath(identifier: "moetTokenVault_\(address)")!
        self.VaultPublicPath = PublicPath(identifier: "moetTokenVault_\(address)")!
        self.ReceiverPublicPath = PublicPath(identifier: "moetTokenReceiver_\(address)")!
        self.AdminStoragePath = StoragePath(identifier: "moetTokenAdmin_\(address)")!


        // Create a public capability to the stored Vault that exposes
        // the `deposit` method and getAcceptedTypes method through the `Receiver` interface
        // and the `balance` method through the `Balance` interface
        //
        self.account.storage.save(<-create Vault(balance: self.totalSupply), to: self.VaultStoragePath)
        let vaultCap = self.account.capabilities.storage.issue<&MOET.Vault>(self.VaultStoragePath)
        self.account.capabilities.publish(vaultCap, at: self.VaultPublicPath)
        let receiverCap = self.account.capabilities.storage.issue<&MOET.Vault>(self.VaultStoragePath)
        self.account.capabilities.publish(receiverCap, at: self.ReceiverPublicPath)

        // Create a Minter & mint the initial supply of tokens to the contract account's Vault
        let admin <- create Minter()

        self.account.capabilities.borrow<&Vault>(self.ReceiverPublicPath)!.deposit(
            from: <- admin.mintTokens(amount: initialMint)
        )

        self.account.storage.save(<-admin, to: self.AdminStoragePath)
    }
}
