// Sets an ERC20 token balance for the signer's COA on EVM (for fork tests).
import EVM from "MockEVM"
import "FlowEVMBridgeUtils"

access(all) fun computeMappingSlot(_ values: [AnyStruct]): String {
    let encoded = EVM.encodeABI(values)
    let hashBytes = HashAlgorithm.KECCAK_256.hash(encoded)
    return String.encodeHex(hashBytes)
}

access(all) fun computeBalanceOfSlot(holderAddress: String, balanceSlot: UInt256): String {
    var addrHex = holderAddress
    if holderAddress.slice(from: 0, upTo: 2) == "0x" {
        addrHex = holderAddress.slice(from: 2, upTo: holderAddress.length)
    }
    let addrBytes = addrHex.decodeHex()
    let address = EVM.EVMAddress(bytes: addrBytes.toConstantSized<[UInt8; 20]>()!)
    return computeMappingSlot([address, balanceSlot])
}

transaction(
    tokenAddress: String,
    balanceSlot: UInt256,
    amount: UFix64
) {
    let holderAddressHex: String

    prepare(signer: auth(Storage) &Account) {
        let coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA at /storage/evm")
        self.holderAddressHex = coa.address().toString()
    }

    execute {
        let token = EVM.addressFromString(tokenAddress)
        let zeroAddress = EVM.addressFromString("0x0000000000000000000000000000000000000000")
        let decimalsCalldata = EVM.encodeABIWithSignature("decimals()", [])
        let decimalsResult = EVM.dryCall(
            from: zeroAddress,
            to: token,
            data: decimalsCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(decimalsResult.status == EVM.Status.successful, message: "Failed to query token decimals")
        let decimals = (EVM.decodeABI(types: [Type<UInt8>()], data: decimalsResult.data)[0] as! UInt8)

        let amountRaw = FlowEVMBridgeUtils.ufix64ToUInt256(value: amount, decimals: decimals)
        let rawBytes = amountRaw.toBigEndianBytes()
        var paddedBytes: [UInt8] = []
        var padCount = 32 - rawBytes.length
        while padCount > 0 {
            paddedBytes.append(0)
            padCount = padCount - 1
        }
        paddedBytes = paddedBytes.concat(rawBytes)
        let valueHex = String.encodeHex(paddedBytes)
        let slotHex = computeBalanceOfSlot(holderAddress: self.holderAddressHex, balanceSlot: balanceSlot)
        EVM.store(target: token, slot: slotHex, value: valueHex)
    }
}
