import "EVM"
import "ERC4626Utils"

/// Check totalAssets and totalSupply for syWFLOWv and FUSDEV vaults
/// Run: flow scripts execute cadence/scripts/diag_evm_vault_state.cdc --network mainnet
access(all) fun main(): {String: String} {
    let result: {String: String} = {}

    let syWFLOWvAddr = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let fusdEvAddr = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")

    // syWFLOWv underlying asset
    let syWFLOWvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: syWFLOWvAddr)
    result["1_syWFLOWv_underlying"] = syWFLOWvUnderlying?.toString() ?? "nil"

    // syWFLOWv totalAssets and totalSupply
    let syWFLOWvTotalAssets = ERC4626Utils.totalAssets(vault: syWFLOWvAddr)
    result["2_syWFLOWv_totalAssets"] = syWFLOWvTotalAssets?.toString() ?? "nil"

    let syWFLOWvTotalShares = ERC4626Utils.totalShares(vault: syWFLOWvAddr)
    result["3_syWFLOWv_totalShares"] = syWFLOWvTotalShares?.toString() ?? "nil"

    // FUSDEV underlying asset
    let fusdEvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: fusdEvAddr)
    result["4_FUSDEV_underlying"] = fusdEvUnderlying?.toString() ?? "nil"

    // FUSDEV totalAssets and totalSupply
    let fusdEvTotalAssets = ERC4626Utils.totalAssets(vault: fusdEvAddr)
    result["5_FUSDEV_totalAssets"] = fusdEvTotalAssets?.toString() ?? "nil"

    let fusdEvTotalShares = ERC4626Utils.totalShares(vault: fusdEvAddr)
    result["6_FUSDEV_totalShares"] = fusdEvTotalShares?.toString() ?? "nil"

    return result
}
