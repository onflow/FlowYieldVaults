import "EVM"
import "FlowEVMBridgeUtils"

/// Returns the ERC-20 balance of an EVM address.
///
/// @param tokenAddressHex: The ERC-20 token contract address
/// @param ownerAddressHex: The EVM address to check balance of
/// @return The balance as UInt256
///
access(all)
fun main(tokenAddressHex: String, ownerAddressHex: String): UInt256 {
    let tokenAddress = EVM.addressFromString(tokenAddressHex)
    let ownerAddress = EVM.addressFromString(ownerAddressHex)

    return FlowEVMBridgeUtils.balanceOf(
        owner: ownerAddress,
        evmContractAddress: tokenAddress
    )
}
