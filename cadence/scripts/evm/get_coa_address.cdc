import "EVM"

/// Gets the EVM address of the account's COA
access(all) fun main(account: Address): String {
    let acct = getAuthAccount<auth(Storage) &Account>(account)
    
    let coa = acct.storage.borrow<&EVM.CadenceOwnedAccount>(from: /storage/evm)
    if coa == nil {
        return "No COA found"
    }
    
    return coa!.address().toString()
}

