import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import MOET from "MOET"
import FungibleToken from "FungibleToken"

/// Redeem MOET for collateral at 1:1 oracle price
///
/// @param moetAmount: Amount of MOET to burn for redemption
transaction(moetAmount: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Withdraw MOET to redeem
        let moetVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)!
            .withdraw(amount: moetAmount)
        
        // Get Flow receiver capability (default collateral)
        let flowReceiver = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        
        // Get redeemer capability from RedemptionWrapper contract
        let redeemer = getAccount(0x0000000000000007)
            .capabilities.borrow<&RedemptionWrapper.Redeemer>(RedemptionWrapper.PublicRedemptionPath)
            ?? panic("No redeemer capability")
        
        // Execute redemption (uses default collateral type)
        redeemer.redeem(
            moet: <-moetVault,
            preferredCollateralType: nil,
            receiver: flowReceiver
        )
    }
}

