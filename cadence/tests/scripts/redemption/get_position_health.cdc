import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"

access(all) fun main(): UFix128 {
    return RedemptionWrapper.getPosition()!.getHealth()
}

