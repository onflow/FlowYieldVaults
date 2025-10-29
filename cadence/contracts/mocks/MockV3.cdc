access(all) contract MockV3 {

    access(all) let PoolStoragePath: StoragePath
    access(all) let PoolPublicPath: PublicPath

    access(all) resource Pool {
        access(all) let poolSizeUSD: UFix64
        access(all) let concentration: UFix64
        access(all) let priceDeviationThreshold: UFix64
        access(all) var maxSafeSingleSwapUSD: UFix64
        access(all) var cumulativeCapacityUSD: UFix64

        access(all) var cumulativeVolumeUSD: UFix64
        access(all) var broken: Bool

        init(
            poolSizeUSD: UFix64,
            concentration: UFix64,
            priceDeviationThreshold: UFix64,
            maxSafeSingleSwapUSD: UFix64,
            cumulativeCapacityUSD: UFix64
        ) {
            self.poolSizeUSD = poolSizeUSD
            self.concentration = concentration
            self.priceDeviationThreshold = priceDeviationThreshold
            self.maxSafeSingleSwapUSD = maxSafeSingleSwapUSD
            self.cumulativeCapacityUSD = cumulativeCapacityUSD
            self.cumulativeVolumeUSD = 0.0
            self.broken = false
        }

        access(all) fun swap(amountUSD: UFix64): Bool {
            if self.broken {
                return false
            }
            if amountUSD > self.maxSafeSingleSwapUSD {
                self.broken = true
                return false
            }
            self.cumulativeVolumeUSD = self.cumulativeVolumeUSD + amountUSD
            if self.cumulativeVolumeUSD > self.cumulativeCapacityUSD {
                self.broken = true
                return false
            }
            return true
        }

        access(all) fun drainLiquidity(percent: UFix64) {
            // percent in [0.0, 1.0]; reduce effective capacity linearly for test purposes
            let factor = 1.0 - percent
            self.cumulativeCapacityUSD = self.cumulativeCapacityUSD * factor
            self.maxSafeSingleSwapUSD = self.maxSafeSingleSwapUSD * factor
        }
    }

    access(all) fun createPool(
        poolSizeUSD: UFix64,
        concentration: UFix64,
        priceDeviationThreshold: UFix64,
        maxSafeSingleSwapUSD: UFix64,
        cumulativeCapacityUSD: UFix64
    ): @Pool {
        return <- create Pool(
            poolSizeUSD: poolSizeUSD,
            concentration: concentration,
            priceDeviationThreshold: priceDeviationThreshold,
            maxSafeSingleSwapUSD: maxSafeSingleSwapUSD,
            cumulativeCapacityUSD: cumulativeCapacityUSD
        )
    }

    init() {
        self.PoolStoragePath = /storage/mockV3Pool
        self.PoolPublicPath = /public/mockV3Pool
    }
}


