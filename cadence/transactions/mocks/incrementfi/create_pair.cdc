import "SwapFactory"
import TokenA from 0xTokenA
import TokenB from 0xTokenB

transaction {
    prepare(acct: AuthAccount) {
        let factory = acct.borrow<&SwapFactory>(from: /storage/factoryPath)!
        factory.createPair(tokenA: TokenA.address, tokenB: TokenB.address)
    }
}
