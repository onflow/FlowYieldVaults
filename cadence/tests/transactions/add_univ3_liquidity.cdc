import "EVM"
import "FungibleToken"
import "FlowToken"

/// Adds liquidity to a UniswapV3 pool using NonfungiblePositionManager.
/// This creates a concentrated liquidity position around the current price.
///
/// @param nftManagerAddressHex: NonfungiblePositionManager address
/// @param token0Hex: First token (sorted by address)
/// @param token1Hex: Second token (sorted by address)
/// @param fee: Pool fee tier (100, 500, 3000, 10000)
/// @param tickLower: Lower tick bound
/// @param tickUpper: Upper tick bound
/// @param amount0Desired: Amount of token0 to add
/// @param amount1Desired: Amount of token1 to add
/// @param amount0Min: Minimum amount of token0 (slippage protection)
/// @param amount1Min: Minimum amount of token1 (slippage protection)
///
transaction(
    nftManagerAddressHex: String,
    token0Hex: String,
    token1Hex: String,
    fee: UInt32,
    tickLower: Int32,
    tickUpper: Int32,
    amount0Desired: UInt256,
    amount1Desired: UInt256,
    amount0Min: UInt256,
    amount1Min: UInt256
) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    let nftManager: EVM.EVMAddress
    let token0: EVM.EVMAddress
    let token1: EVM.EVMAddress

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA from signer")
        
        self.nftManager = EVM.addressFromString(nftManagerAddressHex)
        self.token0 = EVM.addressFromString(token0Hex)
        self.token1 = EVM.addressFromString(token1Hex)
    }

    execute {
        let coaAddress = self.coa.address()
        let deadline = UInt256(getCurrentBlock().timestamp) + 3600 // 1 hour from now

        // 1. Approve token0
        log("Approving token0...")
        let approve0Calldata = EVM.encodeABIWithSignature(
            "approve(address,uint256)",
            [self.nftManager, amount0Desired]
        )
        let approve0Result = self.coa.call(
            to: self.token0,
            data: approve0Calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(approve0Result.status == EVM.Status.successful, message: "Failed to approve token0: ".concat(approve0Result.errorMessage))

        // 2. Approve token1
        log("Approving token1...")
        let approve1Calldata = EVM.encodeABIWithSignature(
            "approve(address,uint256)",
            [self.nftManager, amount1Desired]
        )
        let approve1Result = self.coa.call(
            to: self.token1,
            data: approve1Calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(approve1Result.status == EVM.Status.successful, message: "Failed to approve token1: ".concat(approve1Result.errorMessage))

        // 3. Build mint calldata manually
        // mint((address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,
        //       uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min,
        //       address recipient, uint256 deadline))
        // Function selector for mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))
        // = 0x88316456
        log("Calling NonfungiblePositionManager.mint()...")
        
        // Encode each parameter separately then combine
        let encodedToken0 = EVM.encodeABI([self.token0])
        let encodedToken1 = EVM.encodeABI([self.token1])
        let encodedFee = EVM.encodeABI([UInt256(fee)])
        
        // For int24, we need to sign-extend and encode as int256
        var tickLowerInt256: Int256 = Int256(tickLower)
        var tickUpperInt256: Int256 = Int256(tickUpper)
        let encodedTickLower = EVM.encodeABI([tickLowerInt256])
        let encodedTickUpper = EVM.encodeABI([tickUpperInt256])
        
        let encodedAmount0Desired = EVM.encodeABI([amount0Desired])
        let encodedAmount1Desired = EVM.encodeABI([amount1Desired])
        let encodedAmount0Min = EVM.encodeABI([amount0Min])
        let encodedAmount1Min = EVM.encodeABI([amount1Min])
        let encodedRecipient = EVM.encodeABI([coaAddress])
        let encodedDeadline = EVM.encodeABI([deadline])

        // Function selector: keccak256("mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))")[0:4]
        // = 0x88316456
        var mintCalldata: [UInt8] = [0x88, 0x31, 0x64, 0x56]
        
        // Append all encoded parameters (each is 32 bytes)
        mintCalldata = mintCalldata.concat(encodedToken0)
        mintCalldata = mintCalldata.concat(encodedToken1)
        mintCalldata = mintCalldata.concat(encodedFee)
        mintCalldata = mintCalldata.concat(encodedTickLower)
        mintCalldata = mintCalldata.concat(encodedTickUpper)
        mintCalldata = mintCalldata.concat(encodedAmount0Desired)
        mintCalldata = mintCalldata.concat(encodedAmount1Desired)
        mintCalldata = mintCalldata.concat(encodedAmount0Min)
        mintCalldata = mintCalldata.concat(encodedAmount1Min)
        mintCalldata = mintCalldata.concat(encodedRecipient)
        mintCalldata = mintCalldata.concat(encodedDeadline)

        log("Mint calldata length: ".concat(mintCalldata.length.toString()))

        let mintResult = self.coa.call(
            to: self.nftManager,
            data: mintCalldata,
            gasLimit: 1_000_000,
            value: EVM.Balance(attoflow: 0)
        )

        if mintResult.status != EVM.Status.successful {
            log("Mint failed with error: ".concat(mintResult.errorMessage))
            panic("Failed to mint liquidity position: ".concat(mintResult.errorMessage))
        }

        // Decode result: (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
        let decoded = EVM.decodeABI(
            types: [Type<UInt256>(), Type<UInt256>(), Type<UInt256>(), Type<UInt256>()],
            data: mintResult.data
        )
        
        let tokenId = decoded[0] as! UInt256
        let liquidity = decoded[1] as! UInt256
        let amount0Used = decoded[2] as! UInt256
        let amount1Used = decoded[3] as! UInt256

        log("Successfully minted liquidity position!")
        log("NFT Token ID: ".concat(tokenId.toString()))
        log("Liquidity added: ".concat(liquidity.toString()))
        log("Token0 used: ".concat(amount0Used.toString()))
        log("Token1 used: ".concat(amount1Used.toString()))
    }
}
