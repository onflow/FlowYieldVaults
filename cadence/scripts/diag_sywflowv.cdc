import "EVM"
import "FlowToken"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "ERC4626Utils"

/// Diagnostic script to check syWFLOWv and FUSDEV vault state on mainnet.
/// Run: flow scripts execute cadence/scripts/diag_sywflowv.cdc --network mainnet
///
access(all) fun main(): {String: String} {
    let result: {String: String} = {}

    let syWFLOWvAddr = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let fusdEvAddr = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")

    // Bridge type associations
    let syWFLOWvType = FlowEVMBridgeConfig.getTypeAssociated(with: syWFLOWvAddr)
    result["1_syWFLOWv_typeAssociation"] = syWFLOWvType?.identifier ?? "nil"

    let fusdEvType = FlowEVMBridgeConfig.getTypeAssociated(with: fusdEvAddr)
    result["2_FUSDEV_typeAssociation"] = fusdEvType?.identifier ?? "nil"

    // Underlying asset EVM addresses
    let syWFLOWvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: syWFLOWvAddr)
    result["3_syWFLOWv_underlying"] = syWFLOWvUnderlying?.toString() ?? "nil"

    let fusdEvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: fusdEvAddr)
    result["4_FUSDEV_underlying"] = fusdEvUnderlying?.toString() ?? "nil"

    // FlowToken EVM address association
    let flowTokenType = Type<@FlowToken.Vault>()
    let flowEVMAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: flowTokenType)
    result["5_FlowToken_evmAddress"] = flowEVMAddr?.toString() ?? "nil"

    // syWFLOWv totalAssets and totalSupply
    let syWFLOWvTotalAssets = ERC4626Utils.totalAssets(vault: syWFLOWvAddr)
    result["6_syWFLOWv_totalAssets"] = syWFLOWvTotalAssets?.toString() ?? "nil"

    let syWFLOWvTotalShares = ERC4626Utils.totalShares(vault: syWFLOWvAddr)
    result["7_syWFLOWv_totalShares"] = syWFLOWvTotalShares?.toString() ?? "nil"

    // FUSDEV totalAssets and totalSupply (working reference)
    let fusdEvTotalAssets = ERC4626Utils.totalAssets(vault: fusdEvAddr)
    result["8_FUSDEV_totalAssets"] = fusdEvTotalAssets?.toString() ?? "nil"

    let fusdEvTotalShares = ERC4626Utils.totalShares(vault: fusdEvAddr)
    result["9_FUSDEV_totalShares"] = fusdEvTotalShares?.toString() ?? "nil"

    return result
}
