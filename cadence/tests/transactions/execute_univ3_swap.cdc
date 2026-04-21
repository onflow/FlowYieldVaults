// Generic Uniswap V3 swap: inToken -> outToken on COA.
// Pulls in-token from the COA's EVM balance via EVMTokenConnectors.Source (bridge fee from signer's FlowToken vault),
// then swaps inToken -> outToken. Set the COA's in-token balance first (e.g. set_evm_token_balance for WFLOW).
import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"
import "FlowToken"
import "EVM"
import "FlowEVMBridgeUtils"
import "FlowEVMBridgeConfig"
import "DeFiActions"
import "FungibleTokenConnectors"
import "EVMTokenConnectors"
import "UniswapV3SwapConnectors"

transaction(
    factoryAddress: String,
    routerAddress: String,
    quoterAddress: String,
    inTokenAddress: String,
    outTokenAddress: String,
    poolFee: UInt64,
    amountIn: UFix64
) {
    let coaCap: Capability<auth(EVM.Owner, EVM.Bridge) &EVM.CadenceOwnedAccount>
    let tokenSource: {DeFiActions.Source}
    let outReceiver: &{FungibleToken.Vault}

    prepare(signer: auth(Storage, Capabilities, BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        self.coaCap = signer.capabilities.storage.issue<auth(EVM.Owner, EVM.Bridge) &EVM.CadenceOwnedAccount>(/storage/evm)

        let inAddr = EVM.addressFromString(inTokenAddress)
        // TODO: remove?
        let _inType = FlowEVMBridgeConfig.getTypeAssociated(with: inAddr)!
        let feeVault = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        self.tokenSource = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: feeVault,
            uniqueID: nil
        )

        let outAddr = EVM.addressFromString(outTokenAddress)
        let outType = FlowEVMBridgeConfig.getTypeAssociated(with: outAddr)!
        let tokenContractAddress = FlowEVMBridgeUtils.getContractAddress(fromType: outType)!
        let tokenContractName = FlowEVMBridgeUtils.getContractName(fromType: outType)!
        let viewResolver = getAccount(tokenContractAddress).contracts.borrow<&{ViewResolver}>(name: tokenContractName)!
        let vaultData = viewResolver.resolveContractView(
            resourceType: outType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("No FTVaultData for out token")
        if signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath) == nil {
            signer.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
            let _unpublishedReceiver = signer.capabilities.unpublish(vaultData.receiverPath)
            let _unpublishedMetadata = signer.capabilities.unpublish(vaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: vaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: vaultData.metadataPath)
        }
        self.outReceiver = signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath)!
    }

    execute {
        let inAddr = EVM.addressFromString(inTokenAddress)
        let outAddr = EVM.addressFromString(outTokenAddress)
        let inType = FlowEVMBridgeConfig.getTypeAssociated(with: inAddr)!
        let outType = FlowEVMBridgeConfig.getTypeAssociated(with: outAddr)!

        let inVault <- self.tokenSource.withdrawAvailable(maxAmount: amountIn)

        let factory = EVM.addressFromString(factoryAddress)
        let router = EVM.addressFromString(routerAddress)
        let quoter = EVM.addressFromString(quoterAddress)
        let swapper = UniswapV3SwapConnectors.Swapper(
            factoryAddress: factory,
            routerAddress: router,
            quoterAddress: quoter,
            tokenPath: [inAddr, outAddr],
            feePath: [UInt32(poolFee)],
            inVault: inType,
            outVault: outType,
            coaCapability: self.coaCap,
            uniqueID: nil
        )
        let quote = swapper.quoteOut(forProvided: inVault.balance, reverse: false)
        let outVault <- swapper.swap(quote: quote, inVault: <-inVault)
        self.outReceiver.deposit(from: <-outVault)
    }
}
