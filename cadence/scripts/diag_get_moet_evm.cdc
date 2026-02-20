import "EVM"
import "FlowEVMBridgeConfig"
import "MOET"

access(all) fun main(): String? {
    let evmAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>())
    if evmAddr == nil { return nil }
    return evmAddr!.toString()
}
