import "FungibleToken"

import "MockSwapper"

import "FungibleTokenConnectors"

/// Configures the MockSwapper contract with a liquidity source connected to the signer's Vault at the provided
/// storage path
///
/// @param vaultStoragePath: The StoragePath where the underlying Vault is stored and from which a Capability will be
///     issued
///
transaction(vaultStoragePath: StoragePath) {

    let vaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.vaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(vaultStoragePath)
    }

    execute {
        let vaultConnector = FungibleTokenConnectors.VaultSinkAndSource(
                min: nil,
                max: nil,
                vault: self.vaultCap,
                uniqueID: nil
            )
        MockSwapper.setLiquidityConnector(vaultConnector)
    }
}
