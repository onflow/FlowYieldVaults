import "MOET"
import "EVM"
import "FlowEVMBridgeConfig"

access(all) fun main(): String {
    return FlowEVMBridgeConfig.getEVMAddressAssociated(with: Type<@MOET.Vault>())!.toString()
}
