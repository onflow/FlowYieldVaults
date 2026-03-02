import "EVM"
import "FlowToken"
import "FlowEVMBridgeConfig"

/// Check bridge type/address associations for syWFLOWv and FUSDEV
/// Run: flow scripts execute cadence/scripts/diag_bridge_associations.cdc --network mainnet
access(all) fun main(): {String: String} {
    let result: {String: String} = {}

    let syWFLOWvAddr = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let fusdEvAddr = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")
    let wflowAddr = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e")

    // Bridge type associations for vault EVM addresses
    let syWFLOWvType = FlowEVMBridgeConfig.getTypeAssociated(with: syWFLOWvAddr)
    result["1_syWFLOWv_typeAssociation"] = syWFLOWvType?.identifier ?? "nil"

    let fusdEvType = FlowEVMBridgeConfig.getTypeAssociated(with: fusdEvAddr)
    result["2_FUSDEV_typeAssociation"] = fusdEvType?.identifier ?? "nil"

    // FlowToken -> EVM address
    let flowTokenType = Type<@FlowToken.Vault>()
    let flowEVMAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: flowTokenType)
    result["3_FlowToken_evmAddress"] = flowEVMAddr?.toString() ?? "nil"

    // WFLOW -> Cadence type
    let wflowType = FlowEVMBridgeConfig.getTypeAssociated(with: wflowAddr)
    result["4_WFLOW_typeAssociation"] = wflowType?.identifier ?? "nil"

    return result
}
