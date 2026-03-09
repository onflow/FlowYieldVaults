import "FungibleToken"
import "FungibleTokenMetadataViews"
import "EVM"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"

/// Swap WETH Cadence tokens → WBTC Cadence tokens via the UniV3 WETH/WBTC pool.
/// Sets up the WBTC Cadence vault in signer's storage if not present.
///
/// @param factoryAddr: UniswapV3 factory EVM address (hex, no 0x prefix)
/// @param routerAddr:  UniswapV3 router EVM address
/// @param quoterAddr:  UniswapV3 quoter EVM address
/// @param wethEvmAddr: WETH EVM contract address
/// @param wbtcEvmAddr: WBTC (cbBTC) EVM contract address
/// @param fee:         UniV3 pool fee tier (e.g. 3000)
/// @param wethAmount:  Amount of WETH (Cadence UFix64) to swap for WBTC
///
transaction(
    factoryAddr: String,
    routerAddr:  String,
    quoterAddr:  String,
    wethEvmAddr: String,
    wbtcEvmAddr: String,
    fee: UInt32,
    wethAmount: UFix64
) {
    prepare(signer: auth(Storage, BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability, UnpublishCapability) &Account) {
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

        let wethEVM = EVM.addressFromString(wethEvmAddr)
        let wbtcEVM = EVM.addressFromString(wbtcEvmAddr)

        let wethType = FlowEVMBridgeConfig.getTypeAssociated(with: wethEVM)
            ?? panic("WETH EVM address not registered in bridge config: ".concat(wethEvmAddr))
        let wbtcType = FlowEVMBridgeConfig.getTypeAssociated(with: wbtcEVM)
            ?? panic("WBTC EVM address not registered in bridge config: ".concat(wbtcEvmAddr))

        let swapper = UniswapV3SwapConnectors.Swapper(
            factoryAddress: EVM.addressFromString(factoryAddr),
            routerAddress:  EVM.addressFromString(routerAddr),
            quoterAddress:  EVM.addressFromString(quoterAddr),
            tokenPath: [wethEVM, wbtcEVM],
            feePath:   [fee],
            inVault:   wethType,
            outVault:  wbtcType,
            coaCapability: coaCap,
            uniqueID: nil
        )

        // Locate WETH vault via FTVaultData so we don't hard-code the storage path.
        let wethVaultCompType = CompositeType(wethType.identifier)
            ?? panic("Cannot construct CompositeType for WETH: ".concat(wethType.identifier))
        let wethContract = getAccount(wethVaultCompType.address!).contracts.borrow<&{FungibleToken}>(name: wethVaultCompType.contractName!)
            ?? panic("Cannot borrow FungibleToken contract for WETH")
        let wethVaultData = wethContract.resolveContractView(
            resourceType: wethVaultCompType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Cannot resolve FTVaultData for WETH")

        let wethProvider = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            from: wethVaultData.storagePath
        ) ?? panic("No WETH vault in signer's storage at ".concat(wethVaultData.storagePath.toString()))

        let inVault <- wethProvider.withdraw(amount: wethAmount)

        // Swap WETH → WBTC (bridges to EVM, swaps, bridges back to Cadence).
        let outVault <- swapper.swap(quote: nil, inVault: <-inVault)
        log("Provisioned ".concat(outVault.balance.toString()).concat(" WBTC from ".concat(wethAmount.toString()).concat(" WETH")))

        // Set up WBTC vault in signer's storage if missing.
        let wbtcVaultCompType = CompositeType(wbtcType.identifier)
            ?? panic("Cannot construct CompositeType for WBTC: ".concat(wbtcType.identifier))
        let wbtcContract = getAccount(wbtcVaultCompType.address!).contracts.borrow<&{FungibleToken}>(name: wbtcVaultCompType.contractName!)
            ?? panic("Cannot borrow FungibleToken contract for WBTC")
        let wbtcVaultData = wbtcContract.resolveContractView(
            resourceType: wbtcVaultCompType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Cannot resolve FTVaultData for WBTC")

        if signer.storage.borrow<&{FungibleToken.Vault}>(from: wbtcVaultData.storagePath) == nil {
            signer.storage.save(<-wbtcVaultData.createEmptyVault(), to: wbtcVaultData.storagePath)
            signer.capabilities.unpublish(wbtcVaultData.receiverPath)
            signer.capabilities.unpublish(wbtcVaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(wbtcVaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(wbtcVaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: wbtcVaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: wbtcVaultData.metadataPath)
        }

        let receiver = signer.storage.borrow<&{FungibleToken.Receiver}>(from: wbtcVaultData.storagePath)
            ?? panic("Cannot borrow WBTC vault receiver")
        receiver.deposit(from: <-outVault)
    }
}
