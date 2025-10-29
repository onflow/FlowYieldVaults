import "TidalProtocol"
import "TidalMath"

/// Sets liquidation parameters
transaction(targetHF: UFix64?, warmupSec: UInt64?, protocolFeeBps: UInt16?) {
    prepare(signer: auth(BorrowValue) &Account) {
        let pool = signer.storage.borrow<auth(TidalProtocol.EGovernance) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolStoragePath)")
        
        let targetHF128 = targetHF != nil ? TidalMath.toUFix128(targetHF!) : nil
        
        pool.setLiquidationParams(
            targetHF: targetHF128,
            warmupSec: warmupSec,
            protocolFeeBps: protocolFeeBps
        )
    }
}

