import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowToken from "FlowToken"

access(all) fun main(amount: UFix64, user: Address): Bool {
    return RedemptionWrapper.canRedeem(
        moetAmount: amount,
        collateralType: Type<@FlowToken.Vault>(),
        user: user
    )
}

