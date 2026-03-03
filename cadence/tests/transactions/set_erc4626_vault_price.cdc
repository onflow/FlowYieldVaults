import EVM from "MockEVM"
import "ERC4626Utils"
import "FlowEVMBridgeUtils"

// Helper: Compute Solidity mapping storage slot
access(all) fun computeMappingSlot(_ values: [AnyStruct]): String {
    let encoded = EVM.encodeABI(values)
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)
    return String.encodeHex(hashBytes)
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
// priceMultiplier: share price as a multiplier (e.g. 2.0 for 2x price)
transaction(
    vaultAddress: String,
    assetAddress: String,
    assetBalanceSlot: UInt256,
    totalSupplySlot: UInt256,
    vaultTotalAssetsSlot: UInt256,
    priceMultiplier: UFix64
) {
    prepare(signer: &Account) {}

    execute {
        let vault = EVM.addressFromString(vaultAddress)
        let asset = EVM.addressFromString(assetAddress)
        
        // Query asset decimals from the ERC20 contract
        let zeroAddress = EVM.addressFromString("0x0000000000000000000000000000000000000000")
        let decimalsCalldata = EVM.encodeABIWithSignature("decimals()", [])
        let decimalsResult = EVM.dryCall(
            from: zeroAddress,
            to: asset,
            data: decimalsCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(decimalsResult.status == EVM.Status.successful, message: "Failed to query asset decimals")
        let assetDecimals = (EVM.decodeABI(types: [Type<UInt8>()], data: decimalsResult.data)[0] as! UInt8)
        
        // Query vault decimals
        let vaultDecimalsResult = EVM.dryCall(
            from: zeroAddress,
            to: vault,
            data: decimalsCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(vaultDecimalsResult.status == EVM.Status.successful, message: "Failed to query vault decimals")
        let vaultDecimals = (EVM.decodeABI(types: [Type<UInt8>()], data: vaultDecimalsResult.data)[0] as! UInt8)
        
        // Use 2^120 as base — massive value to drown out interest accrual noise,
        // with room for multipliers up to ~256x within 128-bit _totalAssets field
        let targetAssets: UInt256 = 1 << 120
        // Apply price multiplier via raw fixed-point arithmetic
        // UFix64 internally stores value * 10^8, so we extract the raw representation
        // and do: finalTargetAssets = targetAssets * rawMultiplier / 10^8
        let multiplierBytes = priceMultiplier.toBigEndianBytes()
        var rawMultiplier: UInt256 = 0
        for byte in multiplierBytes {
            rawMultiplier = (rawMultiplier << 8) + UInt256(byte)
        }
        let scale: UInt256 = 100_000_000 // 10^8
        let finalTargetAssets = (targetAssets * rawMultiplier) / scale
        
        // For a 1:1 price (1 share = 1 asset), we need:
        // totalAssets (in assetDecimals) / totalSupply (vault decimals) = 1
        // So: supply_raw = assets_raw * 10^(vaultDecimals - assetDecimals)
        // IMPORTANT: Supply should be based on BASE assets, not multiplied assets (to change price per share)
        let decimalDifference = vaultDecimals - assetDecimals
        let supplyMultiplier = FlowEVMBridgeUtils.pow(base: 10, exponent: decimalDifference)
        let finalTargetSupply = targetAssets * supplyMultiplier
        
        let supplyValue = String.encodeHex(finalTargetSupply.toBigEndianBytes())
        EVM.store(target: vault, slot: String.encodeHex(totalSupplySlot.toBigEndianBytes()), value: supplyValue)
        
        // Update asset.balanceOf(vault) to finalTargetAssets
        let vaultBalanceSlot = computeBalanceOfSlot(holderAddress: vaultAddress, balanceSlot: assetBalanceSlot)
        let targetAssetsValue = String.encodeHex(finalTargetAssets.toBigEndianBytes())
        EVM.store(target: asset, slot: vaultBalanceSlot, value: targetAssetsValue)
        
        // Set vault storage slot (lastUpdate, maxRate, totalAssets packed)
        // For testing, we'll set maxRate to 0 to disable interest rate caps
        let currentTimestamp = UInt64(getCurrentBlock().timestamp)
        let lastUpdateBytes = currentTimestamp.toBigEndianBytes()
        let maxRateBytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]  // maxRate = 0
        
        // Pad finalTargetAssets to 16 bytes for the slot (bytes 16-31, 16 bytes in slot)
        let assetsBytesForSlot = finalTargetAssets.toBigEndianBytes()
        var paddedAssets: [UInt8] = []
        var assetsPadCount = 16 - assetsBytesForSlot.length
        while assetsPadCount > 0 {
            paddedAssets.append(0)
            assetsPadCount = assetsPadCount - 1
        }
        if assetsBytesForSlot.length <= 16 {
            paddedAssets.appendAll(assetsBytesForSlot)
        } else {
            paddedAssets.appendAll(assetsBytesForSlot.slice(from: assetsBytesForSlot.length - 16, upTo: assetsBytesForSlot.length))
        }
        
        // Pack the slot: [lastUpdate(8)] [maxRate(8)] [totalAssets(16)]
        var newSlotBytes: [UInt8] = []
        newSlotBytes.appendAll(lastUpdateBytes)
        newSlotBytes.appendAll(maxRateBytes)
        newSlotBytes.appendAll(paddedAssets)
        
        assert(newSlotBytes.length == 32, message: "Vault storage slot must be exactly 32 bytes, got \(newSlotBytes.length) (lastUpdate: \(lastUpdateBytes.length), maxRate: \(maxRateBytes.length), assets: \(paddedAssets.length))")
        
        let newSlotValue = String.encodeHex(newSlotBytes)
        EVM.store(target: vault, slot: String.encodeHex(vaultTotalAssetsSlot.toBigEndianBytes()), value: newSlotValue)
    }
}
