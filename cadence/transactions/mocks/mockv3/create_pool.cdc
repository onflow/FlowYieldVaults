import "MockV3"

transaction(
    poolSizeUSD: UFix64,
    concentration: UFix64,
    priceDeviationThreshold: UFix64,
    maxSafeSingleSwapUSD: UFix64,
    cumulativeCapacityUSD: UFix64
) {
    prepare(signer: auth(SaveValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        let pool <- MockV3.createPool(
            poolSizeUSD: poolSizeUSD,
            concentration: concentration,
            priceDeviationThreshold: priceDeviationThreshold,
            maxSafeSingleSwapUSD: maxSafeSingleSwapUSD,
            cumulativeCapacityUSD: cumulativeCapacityUSD
        )
        signer.storage.save(<- pool, to: MockV3.PoolStoragePath)
        signer.capabilities.publish(signer.capabilities.storage.issue<&MockV3.Pool>(MockV3.PoolStoragePath), at: MockV3.PoolPublicPath)
    }
}


