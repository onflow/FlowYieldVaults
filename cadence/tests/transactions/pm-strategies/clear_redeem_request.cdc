import "EVM"
import "PMStrategiesV1"

/// Test transaction: cancels a pending deferred redemption.
///
/// @param yieldVaultID: The user's YieldVault ID
///
transaction(yieldVaultID: UInt64) {
    let userCOA: auth(EVM.Call) &EVM.CadenceOwnedAccount

    prepare(signer: auth(BorrowValue) &Account) {
        self.userCOA = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow CadenceOwnedAccount reference from /storage/evm")
    }

    execute {
        PMStrategiesV1.clearRedeemRequest(
            yieldVaultID: yieldVaultID,
            userCOA: self.userCOA
        )
    }
}
