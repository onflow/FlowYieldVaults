import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"
import FlowALPMath from "FlowALPMath"

transaction(cooldown: UFix64, dailyLimit: UFix64, maxPriceAge: UFix64, minHealth: UFix64) {
    prepare(admin: auth(Storage) &Account) {
        let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
            from: RedemptionWrapper.AdminStoragePath
        ) ?? panic("No admin resource")
        
        adminRef.setProtectionParams(
            redemptionCooldownSeconds: cooldown,
            dailyRedemptionLimit: dailyLimit,
            maxPriceAge: maxPriceAge,
            minPostRedemptionHealth: FlowALPMath.toUFix128(minHealth)
        )
    }
}

