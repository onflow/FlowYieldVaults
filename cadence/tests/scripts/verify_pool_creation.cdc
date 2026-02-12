// After pool creation, verify they exist in our test fork
import EVM from "EVM"

access(all) fun main(): {String: String} {
    let coa = getAuthAccount<auth(Storage) &Account>(0xe467b9dd11fa00df)
        .storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
        ?? panic("Could not borrow COA")

    let results: {String: String} = {}

    let factory = EVM.addressFromString("0xca6d7Bb03334bBf135902e1d919a5feccb461632")
    let moet = EVM.addressFromString("0x213979bB8A9A86966999b3AA797C1fcf3B967ae2")
    let fusdev = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")
    let pyusd0 = EVM.addressFromString("0x99aF3EeA856556646C98c8B9b2548Fe815240750")
    let flow = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e")

    // Check the 3 pools we tried to create (WITH CORRECT TOKEN ORDERING)
    let checks = [
        ["PYUSD0_FUSDEV_fee100", pyusd0, fusdev, UInt256(100)],
        ["PYUSD0_FLOW_fee3000", pyusd0, flow, UInt256(3000)],
        ["MOET_FUSDEV_fee100", moet, fusdev, UInt256(100)]
    ]

    var checkIdx = 0
    while checkIdx < checks.length {
        let name = checks[checkIdx][0] as! String
        let token0 = checks[checkIdx][1] as! EVM.EVMAddress
        let token1 = checks[checkIdx][2] as! EVM.EVMAddress
        let fee = checks[checkIdx][3] as! UInt256

        let calldata = EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)",
            [token0, token1, fee]
        )
        let result = coa.dryCall(to: factory, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))

        if result.status == EVM.Status.successful && result.data.length > 0 {
            var isZero = true
            for byte in result.data {
                if byte != 0 {
                    isZero = false
                    break
                }
            }

            if !isZero {
                var addrBytes: [UInt8] = []
                var i = result.data.length - 20
                while i < result.data.length {
                    addrBytes.append(result.data[i])
                    i = i + 1
                }
                results[name] = "POOL EXISTS: 0x".concat(String.encodeHex(addrBytes))
            } else {
                results[name] = "NO (zero address)"
            }
        } else {
            results[name] = "NO (empty)"
        }

        checkIdx = checkIdx + 1
    }

    return results
}