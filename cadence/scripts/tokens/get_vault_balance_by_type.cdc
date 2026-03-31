import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"

/// Returns the Cadence FungibleToken balance for the given account, resolving the
/// vault's public metadata path dynamically via the FTVaultData metadata view.
///
/// Useful for checking balances of VM-bridged ERC-20 tokens without hard-coding public paths.
///
/// @param address:         The account address to check
/// @param vaultIdentifier: The Cadence type identifier (e.g. "A.1e4aa0b87d10b141.EVMVMBridgedToken_...Vault")
/// @return UFix64?:        The vault balance, or nil if the vault is not set up for this account
///
access(all) fun main(address: Address, vaultIdentifier: String): UFix64? {
    let vaultType = CompositeType(vaultIdentifier)
    if vaultType == nil { return nil }

    let contractAddr = vaultType!.address
    if contractAddr == nil { return nil }
    let contractName = vaultType!.contractName
    if contractName == nil { return nil }

    let viewResolver = getAccount(contractAddr!).contracts.borrow<&{ViewResolver}>(name: contractName!)
    if viewResolver == nil { return nil }

    let vaultData = viewResolver!.resolveContractView(
        resourceType: vaultType!,
        viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as? FungibleTokenMetadataViews.FTVaultData
    if vaultData == nil { return nil }

    return getAccount(address).capabilities.borrow<&{FungibleToken.Vault}>(vaultData!.metadataPath)?.balance
}
