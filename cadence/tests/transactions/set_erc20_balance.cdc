import EVM from "MockEVM"

/// Sets the ERC20 balanceOf for a given holder address via direct storage manipulation.
///
/// @param tokenAddress: hex EVM address of the ERC20 contract
/// @param holderAddress: hex EVM address whose balance to set
/// @param balanceSlot: the storage slot index of the _balances mapping in the ERC20 contract
/// @param amount: the raw balance value to write (in smallest token units, e.g. satoshis for wBTC)
///
transaction(tokenAddress: String, holderAddress: String, balanceSlot: UInt256, amount: UInt256) {
    prepare(signer: auth(Storage) &Account) {
        let token = EVM.addressFromString(tokenAddress)

        var addrHex = holderAddress
        if holderAddress.slice(from: 0, upTo: 2) == "0x" {
            addrHex = holderAddress.slice(from: 2, upTo: holderAddress.length)
        }
        let addrBytes = addrHex.decodeHex()
        let holder = EVM.EVMAddress(bytes: addrBytes.toConstantSized<[UInt8; 20]>()!)

        let encoded = EVM.encodeABI([holder, balanceSlot])
        let slotHash = String.encodeHex(HashAlgorithm.KECCAK_256.hash(encoded))

        let raw = amount.toBigEndianBytes()
        var padded: [UInt8] = []
        var padCount = 32 - raw.length
        while padCount > 0 {
            padded.append(0)
            padCount = padCount - 1
        }
        padded = padded.concat(raw)
        let valueHex = String.encodeHex(padded)

        EVM.store(target: token, slot: slotHash, value: valueHex)
    }
}
