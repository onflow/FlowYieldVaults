import "EVM"

/// Gets the FLOW balance of an account's COA on the EVM side
access(all) fun main(account: Address): UFix64 {
    let acct = getAuthAccount<auth(Storage) &Account>(account)
    
    let coa = acct.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
    if coa == nil {
        return 0.0
    }
    
    let balance = coa!.balance()
    return balance.inFLOW()
}

