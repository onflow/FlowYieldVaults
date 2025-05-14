import "FungibleToken"

/// Returns the balance of the stored Vault at the given address if exists, otherwise nil
///
/// @param address: The address of the account that owns the vault
/// @param vaultPathIdentifier: The identifier of the vault's storage path
///
/// @returns The balance of the stored Vault at the given address
///
access(all) fun main(address: Address, vaultPathIdentifier: String): UFix64? {
    let path = StoragePath(identifier: vaultPathIdentifier) ?? panic("Malformed StoragePath identifier")
    return getAuthAccount<auth(BorrowValue) &Account>(address).storage.borrow<&{FungibleToken.Vault}>(
            from: path
        )?.balance ?? nil
}
