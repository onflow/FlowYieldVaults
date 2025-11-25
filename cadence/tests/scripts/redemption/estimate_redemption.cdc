import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowToken from "FlowToken"
import MockOracle from "MockOracle"

access(all) fun main(amount: UFix64): UFix64 {
    // Calculate redemption estimate using oracle price
    let oracle = MockOracle.PriceOracle()
    let collateralPrice = oracle.price(ofToken: Type<@FlowToken.Vault>()) ?? 1.0
    
    // 1:1 parity: collateral = moetAmount / price
    return amount / collateralPrice
}

