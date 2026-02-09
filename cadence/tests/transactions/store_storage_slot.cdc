import EVM from "EVM"

transaction(targetAddress: String, slot: String, value: String) {
    prepare(signer: &Account) {}
    
    execute {
        let target = EVM.addressFromString(targetAddress)
        EVM.store(target: target, slot: slot, value: value)
        log("Stored value at slot ".concat(slot))
    }
}
