// Debug script to understand how Morpho vault calculates totalAssets
import "EVM"

access(all) fun main(): {String: String} {
    let vaultAddress = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"
    let pyusd0Address = "0x99aF3EeA856556646C98c8B9b2548Fe815240750"
    
    let vault = EVM.addressFromString(vaultAddress)
    let pyusd0 = EVM.addressFromString(pyusd0Address)
    
    let coa = getAuthAccount<auth(Storage) &Account>(0xe467b9dd11fa00df)
        .storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
        ?? panic("Could not borrow COA")

    let results: {String: String} = {}

    // 1. Get totalAssets() from vault
    var calldata = EVM.encodeABIWithSignature("totalAssets()", [])
    var result = coa.dryCall(to: vault, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
        results["totalAssets_from_vault"] = (decoded[0] as! UInt256).toString()
    }

    // 2. Get PYUSD0.balanceOf(vault) - the "idle" assets
    calldata = EVM.encodeABIWithSignature("balanceOf(address)", [vault])
    result = coa.dryCall(to: pyusd0, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
        results["pyusd0_balance_of_vault"] = (decoded[0] as! UInt256).toString()
    }

    // 3. Get number of adapters
    calldata = EVM.encodeABIWithSignature("adaptersLength()", [])
    result = coa.dryCall(to: vault, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
        let length = decoded[0] as! UInt256
        results["adaptersLength"] = length.toString()
        
        var totalAllocated: UInt256 = 0
        var i: UInt256 = 0
        while i < length {
            // Get adapter address
            calldata = EVM.encodeABIWithSignature("adapters(uint256)", [i])
            result = coa.dryCall(to: vault, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
            if result.status == EVM.Status.successful {
                let adapterDecoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: result.data)
                let adapterAddr = adapterDecoded[0] as! EVM.EVMAddress
                results["adapter_\(i.toString())_address"] = adapterAddr.toString()

                // Get allocatedAssets for this adapter
                calldata = EVM.encodeABIWithSignature("allocatedAssets(address)", [adapterAddr])
                result = coa.dryCall(to: vault, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
                if result.status == EVM.Status.successful {
                    let allocDecoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
                    let allocated = allocDecoded[0] as! UInt256
                    results["adapter_\(i.toString())_allocatedAssets"] = allocated.toString()
                    totalAllocated = totalAllocated + allocated
                }
            }
            i = i + 1
        }
        results["total_allocated_across_adapters"] = totalAllocated.toString()
    }

    // 4. Calculate expected totalAssets = idle + allocated
    if let idle = results["pyusd0_balance_of_vault"] {
        if let allocated = results["total_allocated_across_adapters"] {
            let idleUInt = UInt256.fromString(idle) ?? 0
            let allocatedUInt = UInt256.fromString(allocated) ?? 0
            let expected = idleUInt + allocatedUInt
            results["calculated_totalAssets"] = expected.toString()
        }
    }

    return results
}
