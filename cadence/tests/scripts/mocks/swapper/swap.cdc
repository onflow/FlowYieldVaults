import "FungibleToken"

import "MockSwapper"

access(all)
fun main(inSource: Address, inVault: String, outVault: String): UFix64 {
    let swapper = MockSwapper.Swapper(
        inVault: CompositeType(inVault)!,
        outVault: CompositeType(outVault)!,
        uniqueID: nil
    )
    let source = getAuthAccount<auth(BorrowValue) &Account>(inSource).storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: /storage/flowTokenVault)!
    
    let out <- swapper.swap(quote: nil, inVault: <-source.withdraw(amount: 100.0))
    let res = out.balance
    destroy out

    return res
}
