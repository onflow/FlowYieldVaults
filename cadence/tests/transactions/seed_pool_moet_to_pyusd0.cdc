import "FungibleToken"
import "FungibleTokenMetadataViews"
import "EVM"
import "MOET"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"

/// Swap MOET → PYUSD0 via UniV3 to seed the PYUSD0/MOET pool with MOET.
///
/// Purpose: the PYUSD0/MOET pool on mainnet can become MOET-depleted (strategies sell MOET
/// for PYUSD0). Before testing PYUSD0→MOET pre-swap, this transaction restores MOET
/// liquidity so the reverse swap is viable.
///
/// The signer must hold MOET in their MOET vault (e.g. from creating a FlowALP position).
/// PYUSD0 received from the swap is deposited into the signer's PYUSD0 vault (set up if absent).
///
/// @param factoryAddr:  UniswapV3 factory EVM address (hex, with 0x prefix)
/// @param routerAddr:   UniswapV3 router EVM address
/// @param quoterAddr:   UniswapV3 quoter EVM address
/// @param moetEvmAddr:  MOET EVM address (e.g. "0x213979bb8a9a86966999b3aa797c1fcf3b967ae2")
/// @param pyusd0EvmAddr: PYUSD0 EVM address
/// @param fee:          UniV3 pool fee tier (100 = 0.01%)
/// @param moetAmount:   Amount of MOET to swap

transaction(
    factoryAddr:  String,
    routerAddr:   String,
    quoterAddr:   String,
    moetEvmAddr:  String,
    pyusd0EvmAddr: String,
    fee:          UInt32,
    moetAmount:   UFix64
) {
    prepare(signer: auth(Storage, BorrowValue, IssueStorageCapabilityController, SaveValue, PublishCapability, UnpublishCapability) &Account) {
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

        let moetEVM   = EVM.addressFromString(moetEvmAddr)
        let pyusd0EVM = EVM.addressFromString(pyusd0EvmAddr)

        let moetType   = Type<@MOET.Vault>()
        let pyusd0Type = FlowEVMBridgeConfig.getTypeAssociated(with: pyusd0EVM)
            ?? panic("PYUSD0 EVM address not registered in bridge config: ".concat(pyusd0EvmAddr))

        let swapper = UniswapV3SwapConnectors.Swapper(
            factoryAddress: EVM.addressFromString(factoryAddr),
            routerAddress:  EVM.addressFromString(routerAddr),
            quoterAddress:  EVM.addressFromString(quoterAddr),
            tokenPath: [moetEVM, pyusd0EVM],
            feePath:   [fee],
            inVault:   moetType,
            outVault:  pyusd0Type,
            coaCapability: coaCap,
            uniqueID: nil
        )

        let moetProvider = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            from: MOET.VaultStoragePath
        ) ?? panic("No MOET vault found in signer storage at ".concat(MOET.VaultStoragePath.toString()).concat(" — ensure the signer created a FlowALP position"))

        let inVault <- moetProvider.withdraw(amount: moetAmount)
        let outVault <- swapper.swap(quote: nil, inVault: <-inVault)
        log("Seeded pool: swapped ".concat(moetAmount.toString()).concat(" MOET → ").concat(outVault.balance.toString()).concat(" PYUSD0"))

        // Deposit PYUSD0 into signer's storage (set up vault if missing).
        let pyusd0CompType = CompositeType(pyusd0Type.identifier)
            ?? panic("Cannot construct CompositeType for PYUSD0: ".concat(pyusd0Type.identifier))
        let pyusd0Contract = getAccount(pyusd0CompType.address!).contracts.borrow<&{FungibleToken}>(name: pyusd0CompType.contractName!)
            ?? panic("Cannot borrow FungibleToken contract for PYUSD0")
        let pyusd0VaultData = pyusd0Contract.resolveContractView(
            resourceType: pyusd0CompType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Cannot resolve FTVaultData for PYUSD0")

        if signer.storage.borrow<&{FungibleToken.Vault}>(from: pyusd0VaultData.storagePath) == nil {
            signer.storage.save(<-pyusd0VaultData.createEmptyVault(), to: pyusd0VaultData.storagePath)
            signer.capabilities.unpublish(pyusd0VaultData.receiverPath)
            signer.capabilities.unpublish(pyusd0VaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(pyusd0VaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(pyusd0VaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: pyusd0VaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: pyusd0VaultData.metadataPath)
        }

        let receiver = signer.storage.borrow<&{FungibleToken.Receiver}>(from: pyusd0VaultData.storagePath)
            ?? panic("Cannot borrow PYUSD0 vault receiver")
        receiver.deposit(from: <-outVault)
    }
}
