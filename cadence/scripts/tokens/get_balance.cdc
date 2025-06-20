import "FungibleToken"

/// Returns a account's balance of a FungibleToken Vault with public Capability published at the provided path
///
access(all)
fun main(address: Address, vaultPublicPath: PublicPath): UFix64? {
    return getAccount(address).capabilities.borrow<&{FungibleToken.Vault}>(vaultPublicPath)?.balance ?? nil
}
