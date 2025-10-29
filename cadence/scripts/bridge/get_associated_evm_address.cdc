import "FlowEVMBridgeConfig"

access(all) fun main(typeIdentifier: String): String? {
    let type = CompositeType(typeIdentifier) ?? panic("Invalid type identifier")
    
    // Query bridge config for associated EVM address
    if let evmAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: type) {
        return evmAddress.toString()
    }
    
    return nil
}

