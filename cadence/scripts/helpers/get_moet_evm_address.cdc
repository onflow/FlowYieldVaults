import "MOET"
import "FlowEVMBridgeConfig"

/// Returns the EVM address for the MOET token (without 0x prefix)
/// Returns nil if MOET hasn't been bridged to EVM yet
///
access(all) fun main(): String? {
    let moetType = Type<@MOET.Vault>()
    if let evmAddr = FlowEVMBridgeConfig.getEVMAddressAssociated(with: moetType) {
        return evmAddr.toString()
    }
    return nil
}

