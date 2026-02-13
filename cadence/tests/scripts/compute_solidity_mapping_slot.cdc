import "EVM"

// Compute Solidity mapping storage slot
// Formula: keccak256(abi.encode(key, mappingSlot))
access(all) fun main(holderAddress: String, slot: UInt256): String {
    // Parse address and encode with slot
    let address = EVM.addressFromString(holderAddress)
    let encoded = EVM.encodeABI([address, slot])

    // Hash with keccak256
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)

    // Convert to hex string with 0x prefix
    return "0x".concat(String.encodeHex(hashBytes))
}
