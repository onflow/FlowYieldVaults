// Transaction to ensure Uniswap V3 pool exists (creates if needed)
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
        
        // First check if pool already exists
        var getPoolCalldata = EVM.encodeABIWithSignature(
            "getPool(address,address,uint24)",
            [token0, token1, UInt256(fee)]
        )
        var getPoolResult = self.coa.dryCall(
            to: factory,
            data: getPoolCalldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        
        assert(getPoolResult.status == EVM.Status.successful, message: "Failed to query pool from factory")
        
        // Decode pool address
        let poolAddress = (EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: getPoolResult.data)[0] as! EVM.EVMAddress)
        let zeroAddress = EVM.EVMAddress(bytes: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
        
        // If pool already exists, we're done (idempotent behavior)
        if poolAddress.bytes != zeroAddress.bytes {
            return
        }
        
        // Pool doesn't exist, create it
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
        
        assert(result.status == EVM.Status.successful, message: "Pool creation failed")
        
        // Get the newly created pool address
        getPoolResult = self.coa.dryCall(to: factory, data: getPoolCalldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
        
        assert(getPoolResult.status == EVM.Status.successful && getPoolResult.data.length >= 20, message: "Failed to get pool address after creation")
        
        // Extract last 20 bytes as pool address
        let poolAddrBytes = getPoolResult.data.slice(from: getPoolResult.data.length - 20, upTo: getPoolResult.data.length)
        let poolAddr = EVM.addressFromString("0x\(String.encodeHex(poolAddrBytes))")
        
        // Initialize the pool with the target price
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
        
        assert(result.status == EVM.Status.successful, message: "Pool initialization failed")
    }
}
