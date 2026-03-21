import "EVM"

/// Queries owner(), masterMinter(), and supplyController() on the PYUSD0 ERC20 contract
/// by making view EVM calls via a known COA (admin account).
///
/// Run on fork:
///   flow scripts execute cadence/scripts/diag_pyusd0_owner.cdc --network mainnet-fork
/// Run on mainnet (read-only):
///   flow scripts execute cadence/scripts/diag_pyusd0_owner.cdc --network mainnet

access(all) fun main(): {String: String} {
    let pyusd0 = EVM.addressFromString("0x99aF3EeA856556646C98c8B9b2548Fe815240750")
    let zero   = EVM.Balance(attoflow: 0)

    // Borrow the admin COA as a plain reference (no entitlements needed for call in view context).
    // The admin account (0xb1d63873c3cc9f79) has a COA at /storage/evm.
    let adminAcct = getAccount(0xb1d63873c3cc9f79)
    let coa = adminAcct.capabilities
        .borrow<&EVM.CadenceOwnedAccount>(/public/evm)

    let result: {String: String} = {}

    if coa == nil {
        result["error"] = "No public COA capability on admin account — run as a transaction instead"
        return result
    }

    // owner() — OpenZeppelin Ownable: selector 0x8da5cb5b
    let ownerRes = coa!.call(
        to: pyusd0,
        data: EVM.encodeABIWithSignature("owner()", []),
        gasLimit: 50_000,
        value: zero
    )
    if ownerRes.status == EVM.Status.successful && ownerRes.data.length >= 32 {
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: ownerRes.data)
        result["owner"] = (decoded[0] as! EVM.EVMAddress).toString()
    } else {
        result["owner"] = "not available (".concat(ownerRes.errorMessage).concat(")")
    }

    // masterMinter() — Circle FiatToken pattern: selector 0x35d99f35
    let mmRes = coa!.call(
        to: pyusd0,
        data: EVM.encodeABIWithSignature("masterMinter()", []),
        gasLimit: 50_000,
        value: zero
    )
    if mmRes.status == EVM.Status.successful && mmRes.data.length >= 32 {
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: mmRes.data)
        result["masterMinter"] = (decoded[0] as! EVM.EVMAddress).toString()
    } else {
        result["masterMinter"] = "not available (".concat(mmRes.errorMessage).concat(")")
    }

    // supplyController() — Paxos pattern: selector 0x9720c7fb
    let scRes = coa!.call(
        to: pyusd0,
        data: EVM.encodeABIWithSignature("supplyController()", []),
        gasLimit: 50_000,
        value: zero
    )
    if scRes.status == EVM.Status.successful && scRes.data.length >= 32 {
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: scRes.data)
        result["supplyController"] = (decoded[0] as! EVM.EVMAddress).toString()
    } else {
        result["supplyController"] = "not available (".concat(scRes.errorMessage).concat(")")
    }

    return result
}
