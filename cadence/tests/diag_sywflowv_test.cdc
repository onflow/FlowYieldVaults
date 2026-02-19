#test_fork(network: "mainnet-fork", height: 142046400)

import Test

import "EVM"
import "FlowToken"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "ERC4626Utils"

access(all) fun testDiagnoseSyWFLOWv() {
    let syWFLOWvAddr = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let fusdEvAddr = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")

    // Check bridge type associations
    let syWFLOWvType = FlowEVMBridgeConfig.getTypeAssociated(with: syWFLOWvAddr)
    log("syWFLOWv type association: ".concat(syWFLOWvType?.identifier ?? "nil"))

    let fusdEvType = FlowEVMBridgeConfig.getTypeAssociated(with: fusdEvAddr)
    log("FUSDEV type association: ".concat(fusdEvType?.identifier ?? "nil"))

    // Check underlying asset
    let syWFLOWvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: syWFLOWvAddr)
    log("syWFLOWv underlying: ".concat(syWFLOWvUnderlying?.toString() ?? "nil"))

    let fusdEvUnderlying = ERC4626Utils.underlyingAssetEVMAddress(vault: fusdEvAddr)
    log("FUSDEV underlying: ".concat(fusdEvUnderlying?.toString() ?? "nil"))

    // Check FlowToken EVM address association
    let flowTokenType = Type<@FlowToken.Vault>()
    let flowEVMAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: flowTokenType)
    log("FlowToken.Vault EVM address: ".concat(flowEVMAddr?.toString() ?? "nil"))

    // Check totalAssets and totalSupply for syWFLOWv
    let syWFLOWvTotalAssets = ERC4626Utils.totalAssets(vault: syWFLOWvAddr)
    log("syWFLOWv totalAssets: ".concat(syWFLOWvTotalAssets?.toString() ?? "nil"))

    let syWFLOWvTotalShares = ERC4626Utils.totalShares(vault: syWFLOWvAddr)
    log("syWFLOWv totalShares: ".concat(syWFLOWvTotalShares?.toString() ?? "nil"))

    // Check totalAssets and totalSupply for FUSDEV (working reference)
    let fusdEvTotalAssets = ERC4626Utils.totalAssets(vault: fusdEvAddr)
    log("FUSDEV totalAssets: ".concat(fusdEvTotalAssets?.toString() ?? "nil"))

    let fusdEvTotalShares = ERC4626Utils.totalShares(vault: fusdEvAddr)
    log("FUSDEV totalShares: ".concat(fusdEvTotalShares?.toString() ?? "nil"))
}
