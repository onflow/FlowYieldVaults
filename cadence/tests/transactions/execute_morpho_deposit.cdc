// Morpho ERC4626 deposit: asset -> vault shares using MorphoERC4626SwapConnectors.
// Signer must have COA, FlowToken vault (for bridge fees), asset vault with balance, and shares vault (created if missing).
import "FungibleToken"
import "FungibleTokenMetadataViews"
import "MetadataViews"
import "FlowToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "DeFiActions"
import "FungibleTokenConnectors"
import "MorphoERC4626SwapConnectors"

transaction(
    assetVaultIdentifier: String,
    erc4626VaultEVMAddressHex: String,
    amountIn: UFix64
) {
    prepare(signer: auth(Storage, Capabilities, BorrowValue) &Account) {
        let erc4626VaultEVMAddress = EVM.addressFromString(erc4626VaultEVMAddressHex)
        let sharesType = FlowEVMBridgeConfig.getTypeAssociated(with: erc4626VaultEVMAddress)
            ?? panic("ERC4626 vault not associated with a Cadence type")

        let assetVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: assetVaultIdentifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for asset")
        let sharesVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: sharesType.identifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for shares")

        if signer.storage.borrow<&{FungibleToken.Vault}>(from: sharesVaultData.storagePath) == nil {
            signer.storage.save(<-sharesVaultData.createEmptyVault(), to: sharesVaultData.storagePath)
            let _unpublishedReceiver = signer.capabilities.unpublish(sharesVaultData.receiverPath)
            let _unpublishedMetadata = signer.capabilities.unpublish(sharesVaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(sharesVaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: sharesVaultData.receiverPath)
            signer.capabilities.publish(receiverCap, at: sharesVaultData.metadataPath)
        }

        let coa = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount>(/storage/evm)
        let feeVault = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: feeVault,
            uniqueID: nil
        )

        let swapper = MorphoERC4626SwapConnectors.Swapper(
            vaultEVMAddress: erc4626VaultEVMAddress,
            coa: coa,
            feeSource: feeSource,
            uniqueID: nil,
            isReversed: false
        )

        let assetVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: assetVaultData.storagePath)
            ?? panic("Missing asset vault")
        let sharesVault = signer.storage.borrow<&{FungibleToken.Vault}>(from: sharesVaultData.storagePath)
            ?? panic("Missing shares vault")

        let inVault <- assetVault.withdraw(amount: amountIn)
        let quote = swapper.quoteOut(forProvided: amountIn, reverse: false)
        let outVault <- swapper.swap(quote: quote, inVault: <-inVault)
        sharesVault.deposit(from: <-outVault)
    }

    execute {}
}
