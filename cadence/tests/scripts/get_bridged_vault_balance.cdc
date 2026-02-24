// Returns the balance of a bridged token vault for an account.
// vaultTypeIdentifier: full type identifier e.g. "A.xxx.EVMVMBridgedToken_d069d989e2f44b70c65347d1853c0c67e10a9f8d.Vault"
import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"
import "FlowEVMBridgeUtils"

access(all)
fun main(address: Address, vaultTypeIdentifier: String): UFix64? {
    let vaultType = CompositeType(vaultTypeIdentifier)
        ?? panic("Invalid vault type identifier: \(vaultTypeIdentifier)")
    let tokenContractAddress = FlowEVMBridgeUtils.getContractAddress(fromType: vaultType)
        ?? panic("No contract address for type")
    let tokenContractName = FlowEVMBridgeUtils.getContractName(fromType: vaultType)
        ?? panic("No contract name for type")
    let viewResolver = getAccount(tokenContractAddress).contracts.borrow<&{ViewResolver}>(name: tokenContractName)
        ?? panic("No ViewResolver for token contract")
    let vaultData = viewResolver.resolveContractView(
        resourceType: vaultType,
        viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as? FungibleTokenMetadataViews.FTVaultData
        ?? panic("No FTVaultData for type")
    return getAccount(address).capabilities.borrow<&{FungibleToken.Vault}>(vaultData.receiverPath)?.balance ?? nil
}
