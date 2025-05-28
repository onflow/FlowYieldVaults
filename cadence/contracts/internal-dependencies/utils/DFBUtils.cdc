import "FungibleToken"

/// DFBUtils
///
/// Utility methods commonly used across DeFiBlocks (DFB) related contracts
///
access(all) contract DFBUtils {

    /// Checks that the contract defining vaultType conforms to the FungibleToken contract interface. This is required
    /// to source empty Vaults in the event inner Capabilities become invalid
    ///
    /// @param vaultType: The Type of the Vault in question
    ///
    /// @return true if the Type a Vault and is defined by a FungibleToken contract, false otherwise
    ///
    access(all) view fun definingContractIsFungibleToken(_ vaultType: Type): Bool {
        if !vaultType.isSubtype(of: Type<@{FungibleToken.Vault}>()) {
            return false
        }
        return getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!) != nil
    }

    /// Returns an empty Vault of the given Type. Reverts if the provided Type is not defined by a FungibleToken
    /// or if the returned Vault is not of the requested Type. Callers can use .definingContractIsFungibleToken()
    /// to check the type before calling if they would like to prevent reverting.
    ///
    /// @param vaultType: The Type of the Vault to return as an empty Vault
    ///
    /// @return an empty Vault of the requested Type
    ///
    access(all) fun getEmptyVault(_ vaultType: Type): @{FungibleToken.Vault} {
        pre {
            self.definingContractIsFungibleToken(vaultType):
            "Invalid vault Type \(vaultType.identifier) requested - cannot fulfill an empty Vault of an invalid type"
        }
        post {
            result.getType() == vaultType:
            "Invalid Vault returned - expected \(vaultType.identifier) but returned \(result.getType().identifier)"
        }
        return <- getAccount(vaultType.address!)
            .contracts
            .borrow<&{FungibleToken}>(name: vaultType.contractName!)!
            .createEmptyVault(vaultType: vaultType)
    }
}
