import "EVM"
import "FlowEVMBridgeUtils"

/// Returns the ERC20 balances of all tokens relevant to FlowYieldVaultsStrategiesV2
/// for a given EVM address (e.g. a user's COA, the strategy contract, or a pool address).
///
/// For each token reports:
///   balance     – human-readable amount (token units, 8 dp precision)
///   balance_wei – raw amount in the token's smallest unit
///   decimals    – the token's ERC20 decimal count
///
/// Run:
///   flow scripts execute cadence/scripts/diag_evm_token_balances.cdc \
///     --args-json '[{"type":"String","value":"0xYOUR_EVM_ADDRESS"}]' \
///     --network mainnet
access(all) fun main(evmAddressHex: String): {String: {String: AnyStruct}} {

    let target = EVM.addressFromString(evmAddressHex)
    let caller = EVM.addressFromString("0xca6d7Bb03334bBf135902e1d919a5feccb461632") // factory, used as from

    // ── Token EVM addresses ────────────────────────────────────────────────────
    let tokens: {String: EVM.EVMAddress} = {
        "MOET":     EVM.addressFromString("0x213979bb8a9a86966999b3aa797c1fcf3b967ae2"),
        "PYUSD0":   EVM.addressFromString("0x99aF3EeA856556646C98c8B9b2548Fe815240750"),
        "FUSDEV":   EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D"),
        "WFLOW":    EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"),
        "syWFLOWv": EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"),
        "WETH":     EVM.addressFromString("0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590"),
        "WBTC":     EVM.addressFromString("0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579")
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    fun call(_ to: EVM.EVMAddress, _ data: [UInt8]): EVM.Result {
        return EVM.dryCall(
            from: caller, to: to, data: data,
            gasLimit: 100_000, value: EVM.Balance(attoflow: 0)
        )
    }

    fun toHuman(_ wei: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: wei, decimals: decimals)
        }
        let quantum = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        return FlowEVMBridgeUtils.uint256ToUFix64(value: wei - (wei % quantum), decimals: decimals)
    }

    // ── Query each token ───────────────────────────────────────────────────────
    var result: {String: {String: AnyStruct}} = {}

    for name in tokens.keys {
        let tokenAddr = tokens[name]!
        var entry: {String: AnyStruct} = {}

        let decimals = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: tokenAddr)
        entry["decimals"] = decimals

        let balRes = call(tokenAddr, EVM.encodeABIWithSignature("balanceOf(address)", [target]))
        if balRes.status == EVM.Status.successful {
            let wei = EVM.decodeABI(types: [Type<UInt256>()], data: balRes.data)[0] as! UInt256
            entry["balance"]     = toHuman(wei, decimals)
            entry["balance_wei"] = wei
        } else {
            entry["error"] = "balanceOf call failed: ".concat(balRes.errorMessage)
        }

        result[name] = entry
    }

    return result
}
