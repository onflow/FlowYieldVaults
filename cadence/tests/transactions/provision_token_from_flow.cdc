import "FungibleToken"
import "FungibleTokenMetadataViews"
import "FlowToken"
import "EVM"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"

/// Swaps native FLOW from the signer's FlowToken vault to a target EVM-bridged token via
/// Uniswap V3, and deposits the result into the signer's Cadence storage.
///
/// This works because WFLOW (the EVM ERC-20 wrapper for FLOW) is registered in
/// FlowEVMBridgeConfig as the EVM representation of FlowToken.Vault. The Swapper
/// bridges FlowToken → WFLOW in EVM, swaps via UniV3, then bridges the output back.
///
/// Example usages (mainnet):
///   FLOW → WETH:   tokenInEvm = WFLOW, tokenOutEvm = WETH,   fee = 3000
///   FLOW → PYUSD0: tokenInEvm = WFLOW, tokenOutEvm = PYUSD0, fee = 100
///
/// @param factoryAddr  UniV3 factory EVM address (hex, with 0x prefix)
/// @param routerAddr   UniV3 router EVM address
/// @param quoterAddr   UniV3 quoter EVM address
/// @param tokenInEvm   WFLOW EVM address (must be registered in FlowEVMBridgeConfig as FlowToken.Vault)
/// @param tokenOutEvm  Target token EVM address (must be onboarded to FlowEVMBridge)
/// @param fee          UniV3 pool fee tier (e.g. 3000 = 0.3%, 100 = 0.01%)
/// @param flowAmount   Amount of FLOW (UFix64) to swap
///
transaction(
    factoryAddr: String,
    routerAddr:  String,
    quoterAddr:  String,
    tokenInEvm:  String,
    tokenOutEvm: String,
    fee:         UInt32,
    flowAmount:  UFix64
) {
    prepare(signer: auth(Storage, BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability, UnpublishCapability) &Account) {

        // Issue a COA capability so the Swapper can bridge tokens via the signer's COA.
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

        let wflowEVM = EVM.addressFromString(tokenInEvm)
        let outEVM   = EVM.addressFromString(tokenOutEvm)

        // FlowToken.Vault is the Cadence representation of WFLOW in FlowEVMBridgeConfig.
        let flowVaultType = FlowEVMBridgeConfig.getTypeAssociated(with: wflowEVM)
            ?? panic("WFLOW EVM address is not registered in FlowEVMBridgeConfig: ".concat(tokenInEvm))
        let outVaultType = FlowEVMBridgeConfig.getTypeAssociated(with: outEVM)
            ?? panic("Target EVM address is not registered in FlowEVMBridgeConfig: ".concat(tokenOutEvm))

        let swapper = UniswapV3SwapConnectors.Swapper(
            factoryAddress: EVM.addressFromString(factoryAddr),
            routerAddress:  EVM.addressFromString(routerAddr),
            quoterAddress:  EVM.addressFromString(quoterAddr),
            tokenPath: [wflowEVM, outEVM],
            feePath:   [fee],
            inVault:   flowVaultType,
            outVault:  outVaultType,
            coaCapability: coaCap,
            uniqueID: nil
        )

        // Withdraw FLOW from the signer's FlowToken vault.
        let flowProvider = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Signer has no FlowToken vault at /storage/flowTokenVault")
        let inVault <- flowProvider.withdraw(amount: flowAmount)

        // Swap: bridges FLOW → WFLOW in EVM, swaps via UniV3, bridges result back to Cadence.
        let outVault <- swapper.swap(quote: nil, inVault: <-inVault)
        log("Provisioned ".concat(outVault.balance.toString()).concat(" of ").concat(outVaultType.identifier)
            .concat(" from ").concat(flowAmount.toString()).concat(" FLOW"))

        // Ensure the output vault exists in signer's Cadence storage.
        let outCompType = CompositeType(outVaultType.identifier)
            ?? panic("Cannot construct CompositeType for output vault: ".concat(outVaultType.identifier))
        let outContract = getAccount(outCompType.address!).contracts.borrow<&{FungibleToken}>(name: outCompType.contractName!)
            ?? panic("Cannot borrow FungibleToken contract for output token")
        let outVaultData = outContract.resolveContractView(
            resourceType: outCompType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Cannot resolve FTVaultData for output token")

        if signer.storage.borrow<&{FungibleToken.Vault}>(from: outVaultData.storagePath) == nil {
            signer.storage.save(<-outVaultData.createEmptyVault(), to: outVaultData.storagePath)
            signer.capabilities.unpublish(outVaultData.receiverPath)
            signer.capabilities.unpublish(outVaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(outVaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(outVaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: outVaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: outVaultData.metadataPath)
        }

        let receiver = signer.storage.borrow<&{FungibleToken.Receiver}>(from: outVaultData.storagePath)
            ?? panic("Cannot borrow receiver for output vault")
        receiver.deposit(from: <-outVault)
    }
}
