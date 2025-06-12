import "FungibleToken"

/// Returns the balance of the stored Vault at the given address if exists, otherwise nil
///
/// @param address: The address of the account that owns the vault
/// @param vaultStoragePath: The StoragePath where the Vault can be found
///
/// @returns The balance of the stored Vault at the given address or `nil` if the Vault is not found
///
access(all) fun main(address: Address, vaultStoragePath: StoragePath): UFix64? {
    return getAuthAccount<auth(BorrowValue) &Account>(address).storage.borrow<&{FungibleToken.Vault}>(
            from: vaultStoragePath
        )?.balance ?? nil
}
