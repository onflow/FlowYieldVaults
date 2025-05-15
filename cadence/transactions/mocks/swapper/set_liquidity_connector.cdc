import "FungibleToken"

import "MockSwapper"

import "FungibleTokenStack"
import "DFB"

transaction(vaultStoragePath: StoragePath) {

    let vaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.vaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(vaultStoragePath)
    }

    execute {
        let vaultConnector = FungibleTokenStack.VaultSinkAndSource(
                min: nil,
                max: nil,
                vault: self.vaultCap,
                uniqueID: nil
            )
        MockSwapper.setLiquidityConnector(vaultConnector)
    }
}
