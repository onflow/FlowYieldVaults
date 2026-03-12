import "FungibleToken"
import "FlowToken"
import "EVM"
import "PMStrategiesV1"

/// Test transaction: requests a deferred redemption for a syWFLOWv yield vault.
/// Single signer — test accounts can pay their own scheduling fees.
///
/// @param yieldVaultID: The user's YieldVault ID
/// @param amount: Underlying asset amount to redeem (nil = all)
/// @param schedulingFeeAmount: FlowToken amount for FlowTransactionScheduler fees
///
transaction(
    yieldVaultID: UInt64,
    amount: UFix64?,
    schedulingFeeAmount: UFix64
) {
    let userCOA: auth(EVM.Call) &EVM.CadenceOwnedAccount
    let userAddress: Address
    let fees: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        self.userAddress = signer.address

        self.userCOA = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow CadenceOwnedAccount reference from /storage/evm")

        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken Vault reference from /storage/flowTokenVault")
        self.fees <- flowVault.withdraw(amount: schedulingFeeAmount) as! @FlowToken.Vault
    }

    execute {
        PMStrategiesV1.requestRedeem(
            yieldVaultID: yieldVaultID,
            amount: amount,
            userCOA: self.userCOA,
            userFlowAddress: self.userAddress,
            fees: <-self.fees
        )
    }
}
