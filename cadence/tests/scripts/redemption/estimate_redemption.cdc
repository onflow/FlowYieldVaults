import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowToken from "FlowToken"

access(all) fun main(amount: UFix64): UFix64 {
    return RedemptionWrapper.estimateRedemption(
        moetAmount: amount,
        collateralType: Type<@FlowToken.Vault>()
    )
}

