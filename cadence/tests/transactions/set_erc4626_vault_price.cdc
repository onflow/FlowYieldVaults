import EVM from "MockEVM"

// Helper: Compute Solidity mapping storage slot
access(all) fun computeMappingSlot(_ values: [AnyStruct]): String {
    let encoded = EVM.encodeABI(values)
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)
    return "0x\(String.encodeHex(hashBytes))"
}

// Helper: Compute ERC20 balanceOf storage slot
access(all) fun computeBalanceOfSlot(holderAddress: String, balanceSlot: UInt256): String {
    var addrHex = holderAddress
    if holderAddress.slice(from: 0, upTo: 2) == "0x" {
        addrHex = holderAddress.slice(from: 2, upTo: holderAddress.length)
    }
    let addrBytes = addrHex.decodeHex()
    let address = EVM.EVMAddress(bytes: addrBytes.toConstantSized<[UInt8; 20]>()!)
    return computeMappingSlot([address, balanceSlot])
}

// Atomically set ERC4626 vault share price
// This manipulates both the underlying asset balance and vault's _totalAssets storage slot
// If targetTotalAssets is 0, multiplies current totalAssets by priceMultiplier
// If targetTotalAssets is non-zero, uses it directly (priceMultiplier is ignored)
transaction(
    vaultAddress: String,
    assetAddress: String,
    assetBalanceSlot: UInt256,
    vaultTotalAssetsSlot: String,
    priceMultiplier: UFix64,
    targetTotalAssets: UInt256
) {
    prepare(signer: &Account) {}

    execute {
        let vault = EVM.addressFromString(vaultAddress)
        let asset = EVM.addressFromString(assetAddress)
        
        var targetAssets: UInt256 = targetTotalAssets
        
        // If targetTotalAssets is 0, calculate from current assets * multiplier
        if targetTotalAssets == UInt256(0) {
            // Read current totalAssets from vault via EVM call
            let totalAssetsCalldata = EVM.encodeABIWithSignature("totalAssets()", [])
            let totalAssetsResult = EVM.call(
                from: vaultAddress,
                to: vaultAddress,
                data: totalAssetsCalldata,
                gasLimit: 100000,
                value: 0
            )
            
            assert(totalAssetsResult.status == EVM.Status.successful, message: "Failed to read totalAssets")
            
            let currentAssets = (EVM.decodeABI(types: [Type<UInt256>()], data: totalAssetsResult.data)[0] as! UInt256)
            
            // Calculate target assets (currentAssets * multiplier / 1e8)
            // priceMultiplier is UFix64, so convert to UInt64 via big-endian bytes
            let multiplierBytes = priceMultiplier.toBigEndianBytes()
            var multiplierUInt64: UInt64 = 0
            for byte in multiplierBytes {
                multiplierUInt64 = (multiplierUInt64 << 8) + UInt64(byte)
            }
            targetAssets = (currentAssets * UInt256(multiplierUInt64)) / UInt256(100000000)
        }
        
        // Update asset.balanceOf(vault) to targetAssets
        let vaultBalanceSlot = computeBalanceOfSlot(holderAddress: vaultAddress, balanceSlot: assetBalanceSlot)
        
        // Pad targetAssets to 32 bytes
        let targetAssetsBytes = targetAssets.toBigEndianBytes()
        var paddedTargetAssets: [UInt8] = []
        var padCount = 32 - targetAssetsBytes.length
        while padCount > 0 {
            paddedTargetAssets.append(0)
            padCount = padCount - 1
        }
        paddedTargetAssets.appendAll(targetAssetsBytes)
        
        let targetAssetsValue = "0x".concat(String.encodeHex(paddedTargetAssets))
        EVM.store(target: asset, slot: vaultBalanceSlot, value: targetAssetsValue)
        
        // Read current vault storage slot (contains lastUpdate, maxRate, and totalAssets packed)
        let slotBytes = EVM.load(target: vault, slot: vaultTotalAssetsSlot)
        
        assert(slotBytes.length == 32, message: "Vault storage slot must be 32 bytes")
        
        // Extract maxRate (bytes 8-15, 8 bytes)
        let maxRateBytes = slotBytes.slice(from: 8, upTo: 16)
        
        // Get current block timestamp for lastUpdate (bytes 0-7, 8 bytes)
        let currentTimestamp = UInt64(getCurrentBlock().timestamp)
        let lastUpdateBytes = currentTimestamp.toBigEndianBytes()
        
        // Pad targetAssets to 16 bytes for the slot (bytes 16-31, 16 bytes in slot)
        // Re-get bytes from targetAssets to avoid using the 32-byte padded version
        let assetsBytesForSlot = targetAssets.toBigEndianBytes()
        var paddedAssets: [UInt8] = []
        var assetsPadCount = 16 - assetsBytesForSlot.length
        while assetsPadCount > 0 {
            paddedAssets.append(0)
            assetsPadCount = assetsPadCount - 1
        }
        // Only take last 16 bytes if assetsBytesForSlot is somehow longer than 16
        if assetsBytesForSlot.length <= 16 {
            paddedAssets.appendAll(assetsBytesForSlot)
        } else {
            // Take last 16 bytes if longer
            paddedAssets.appendAll(assetsBytesForSlot.slice(from: assetsBytesForSlot.length - 16, upTo: assetsBytesForSlot.length))
        }
        
        // Pack the slot: [lastUpdate(8)] [maxRate(8)] [totalAssets(16)]
        var newSlotBytes: [UInt8] = []
        newSlotBytes.appendAll(lastUpdateBytes)
        newSlotBytes.appendAll(maxRateBytes)
        newSlotBytes.appendAll(paddedAssets)
        
        assert(newSlotBytes.length == 32, message: "Vault storage slot must be exactly 32 bytes, got \(newSlotBytes.length) (lastUpdate: \(lastUpdateBytes.length), maxRate: \(maxRateBytes.length), assets: \(paddedAssets.length))")
        
        let newSlotValue = "0x".concat(String.encodeHex(newSlotBytes))
        EVM.store(target: vault, slot: vaultTotalAssetsSlot, value: newSlotValue)
    }
}
