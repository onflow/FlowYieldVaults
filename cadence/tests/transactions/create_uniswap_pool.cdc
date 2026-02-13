// Transaction to create Uniswap V3 pools
import "EVM"

transaction(
    factoryAddress: String,
    token0Address: String,
    token1Address: String,
    fee: UInt64,
    sqrtPriceX96: String
) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    
    prepare(signer: auth(Storage) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA")
    }
    
    execute {
        let factory = EVM.addressFromString(factoryAddress)
        let token0 = EVM.addressFromString(token0Address)
        let token1 = EVM.addressFromString(token1Address)
        
        var calldata = EVM.encodeABIWithSignature(
            "createPool(address,address,uint24)",
            [token0, token1, UInt256(fee)]
        )
        var result = self.coa.call(
            to: factory,
            data: calldata,
            gasLimit: 5000000,
            value: EVM.Balance(attoflow: 0)
        )
        
        if result.status == EVM.Status.successful {
            calldata = EVM.encodeABIWithSignature(
                "getPool(address,address,uint24)",
                [token0, token1, UInt256(fee)]
            )
            result = self.coa.dryCall(to: factory, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
            
            if result.status == EVM.Status.successful && result.data.length >= 20 {
                var poolAddrBytes: [UInt8] = []
                var i = result.data.length - 20
                while i < result.data.length {
                    poolAddrBytes.append(result.data[i])
                    i = i + 1
                }
                let poolAddr = EVM.addressFromString("0x".concat(String.encodeHex(poolAddrBytes)))
                
                let initPrice = UInt256.fromString(sqrtPriceX96)!
                calldata = EVM.encodeABIWithSignature(
                    "initialize(uint160)",
                    [initPrice]
                )
                result = self.coa.call(
                    to: poolAddr,
                    data: calldata,
                    gasLimit: 5000000,
                    value: EVM.Balance(attoflow: 0)
                )
            }
        }
    }
}
