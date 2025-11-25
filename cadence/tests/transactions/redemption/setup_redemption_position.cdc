import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowToken from "FlowToken"
import MOET from "MOET"
import FlowALP from "FlowALP"
import FungibleToken from "FungibleToken"
import FungibleTokenConnectors from "FungibleTokenConnectors"

/// Setup the RedemptionWrapper's redemption position with initial collateral
///
/// @param flowAmount: Amount of Flow to deposit as initial collateral
transaction(flowAmount: UFix64) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Withdraw Flow collateral
        let flowVault <- signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)!
            .withdraw(amount: flowAmount)
        
        // Create issuance sink (where borrowed MOET will be sent)
        let moetVaultCap = signer.capabilities.get<&MOET.Vault>(MOET.VaultPublicPath)
        let issuanceSink = FungibleTokenConnectors.VaultSink(
            max: nil,
            depositVault: moetVaultCap,
            uniqueID: nil
        )
        
        // Borrow Admin resource
        let adminRef = signer.storage.borrow<&RedemptionWrapper.Admin>(
            from: RedemptionWrapper.AdminStoragePath
        ) ?? panic("No admin resource - setup requires Admin authorization")

        // Setup redemption position (no repayment source for testing simplicity)
        RedemptionWrapper.setup(
            admin: adminRef,
            initialCollateral: <-flowVault,
            issuanceSink: issuanceSink,
            repaymentSource: nil
        )
    }
}

