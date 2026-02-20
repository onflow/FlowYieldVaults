import EVM from "EVM"

access(all) fun main(targetAddress: String, slot: String): String {
    let target = EVM.addressFromString(targetAddress)
    let value = EVM.load(target: target, slot: slot)
    return String.encodeHex(value)
}