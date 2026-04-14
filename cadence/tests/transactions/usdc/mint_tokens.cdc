import "FungibleToken"
import "USDCFlow"
import "FungibleTokenMetadataViews"

import "FlowEVMBridgeHandlerInterfaces"

/// This transaction is what the minter Account uses to mint new ExampleTokens
/// They provide the recipient address and amount to mint, and the tokens
/// are transferred to the address after minting

transaction(recipient: Address, amount: UFix64) {

    /// Reference to the Example Token Minter Resource object
    let tokenMinter: auth(FlowEVMBridgeHandlerInterfaces.Mint) &USDCFlow.Minter

    /// Reference to the Fungible Token Receiver of the recipient
    let tokenReceiver: &{FungibleToken.Receiver}

    /// The total supply of tokens before the burn
    let supplyBefore: UFix64

    prepare(signer: auth(BorrowValue) &Account) {
        self.supplyBefore = USDCFlow.totalSupply

        // Borrow a reference to the admin object
        self.tokenMinter = signer.storage.borrow<auth(FlowEVMBridgeHandlerInterfaces.Mint) &USDCFlow.Minter>(
                from: /storage/usdcFlowMinter
            ) ?? panic("Signer is not the token admin")

        let vaultData = USDCFlow.resolveContractView(
                resourceType: nil,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not get vault data view for the contract")
    
        self.tokenReceiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(vaultData.receiverPath)
            ?? panic("Could not borrow receiver reference to the Vault")
    }

    execute {

        // Create mint tokens
        let mintedVault <- self.tokenMinter.mint(amount: amount)

        // Deposit them to the receiever
        self.tokenReceiver.deposit(from: <-mintedVault)
    }

    post {
        USDCFlow.totalSupply == self.supplyBefore + amount: "The total supply must be increased by the amount"
    }
}
