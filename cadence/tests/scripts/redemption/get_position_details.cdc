import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowALP from "FlowALP"
import MOET from "MOET"
import FlowToken from "FlowToken"

access(all) fun main(): {String: UFix64} {
    let position = RedemptionWrapper.getPosition()!
    let balances = position.getBalances()
    
    var flowCollateral: UFix64 = 0.0
    var moetDebt: UFix64 = 0.0
    
    for bal in balances {
        if bal.vaultType == Type<@FlowToken.Vault>() && bal.direction == FlowALP.BalanceDirection.Credit {
            flowCollateral = bal.balance
        }
        if bal.vaultType == Type<@MOET.Vault>() && bal.direction == FlowALP.BalanceDirection.Debit {
            moetDebt = bal.balance
        }
    }
    
    return {
        "flowCollateral": flowCollateral,
        "moetDebt": moetDebt
    }
}

